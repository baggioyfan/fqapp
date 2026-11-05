// The desktop player receives clear bytes over a per-player loopback capability.
// Keys and original URLs stay inside the process; no decrypted movie is written.
// 合并说明：fork 侧保留自己的解析路径（ipv4_first / Content-Range 读总长），
// 上游侧新增了全局 shared_client 与按已知长度的分段拉取，两边代码在合并后同时
// 存在，所以两套符号都要引；net 里 Shutdown 只给上游的 socket 收尾用。
use crate::desktop_fetch::{
    content_range, fetch_known_range, fetch_range, shared_client, with_retries, FetchError,
    OpenError, CHUNK_TIMEOUT, PROBE_TIMEOUT,
};
use reqwest::{blocking::Client, header};
use serde::Deserialize;
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs},
    ptr,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
struct SpError {
    code: i32,
    message: [c_char; 192],
}
#[repr(C)]
struct SpIo {
    user: *mut c_void,
    size: extern "C" fn(*mut c_void) -> i64,
    read_at: extern "C" fn(*mut c_void, u64, *mut u8, usize) -> isize,
    cancel: extern "C" fn(*mut c_void),
    close: extern "C" fn(*mut c_void),
}
unsafe extern "C" {
    fn sp_stream_open(io: *const SpIo, key: *const u8, error: *mut SpError) -> *mut c_void;
    fn sp_stream_read(
        stream: *mut c_void,
        buffer: *mut u8,
        length: usize,
        error: *mut SpError,
    ) -> isize;
    fn sp_stream_seek(stream: *mut c_void, position: i64, error: *mut SpError) -> i64;
    fn sp_stream_size(stream: *const c_void) -> i64;
    fn sp_stream_close(stream: *mut c_void);
}

/// Media hosts publish both A and AAAA records, and macOS orders AAAA first
/// (RFC 6724). A burst of fresh IPv6 connections on some home networks drops
/// the first SYN without a RST, so each of those connects pays a 1/2/4 s TCP
/// retransmission ladder and can burn the whole connect budget: measured on a
/// failing host, 8 of 11 parallel IPv6 connects stalled 1–6 s while the same
/// 11 over IPv4 stayed at 9–22 ms. Resolve once here and hand reqwest an
/// explicit list with every IPv4 address first, IPv6 kept as the fallback.
fn ipv4_first(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let mut ordered: Vec<SocketAddr> = Vec::with_capacity(addrs.len());
    ordered.extend(addrs.iter().filter(|addr| addr.is_ipv4()).copied());
    ordered.extend(addrs.iter().filter(|addr| addr.is_ipv6()).copied());
    ordered
}

/// 每个 host 一个媒体 client。
///
/// 上游把它做成一个全局 `shared_client()`，但 `resolve_to_addrs` 是 **build 期
/// 按 host 绑定的**：一个 client 只能固定一份地址表，装不下「每个 host 都把
/// A 记录排到 AAAA 前面」这条修（家宽 IPv6 突发丢 SYN：成功 249–310ms、失败
/// 8051–8112ms，中间没有值）。按 host 缓存既保住这条修，又照样跨会话复用
/// 连接池，代价只是每个 host 泄漏一个 `Client`（数量 = 不同 CDN 域名数）。
fn media_client(url: &str) -> Result<&'static Client, OpenError> {
    static CLIENTS: OnceLock<Mutex<HashMap<String, &'static Client>>> = OnceLock::new();
    let parsed = url::Url::parse(url).ok();
    let host = parsed
        .as_ref()
        .and_then(|parsed| parsed.domain().map(str::to_string))
        .unwrap_or_default();
    let cache = CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    {
        let guard = cache
            .lock()
            .map_err(|_| OpenError::new("无法初始化媒体连接", "other"))?;
        if let Some(client) = guard.get(&host) {
            return Ok(client);
        }
    }
    let mut builder = Client::builder()
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .pool_idle_timeout(Duration::from_secs(120));
    // `domain()` is None for IP literals, which must keep the default resolver.
    if let Some(parsed) = &parsed {
        if let Some(host) = parsed.domain() {
            let port = parsed.port_or_known_default().unwrap_or(443);
            if let Ok(addrs) = (host, port).to_socket_addrs() {
                let ordered = ipv4_first(addrs.collect());
                if !ordered.is_empty() {
                    builder = builder.resolve_to_addrs(host, &ordered);
                }
            }
        }
    }
    let built = builder
        .build()
        .map_err(|_| OpenError::new("无法初始化媒体连接", "other"))?;
    let leaked: &'static Client = Box::leak(Box::new(built));
    let mut guard = cache
        .lock()
        .map_err(|_| OpenError::new("无法初始化媒体连接", "other"))?;
    Ok(*guard.entry(host).or_insert(leaked))
}

/// 探测首字节并取回总长度。
///
/// 与 `fetch_range` 的差别只有一处：非 206 时把响应体前 128 个字符打到 stderr。
/// CDN 对约 35% 的取流请求返 403，而拒绝理由（签名无效 / 防盗链 / 限流）只写在
/// 响应体里，单看状态码分不清是哪一种。诊断完把 `CAPTURE_ERROR_BODY` 置 false
/// 即退回「只有状态码」，连同这个函数一起去掉。
fn probe(client: &Client, url: &str) -> Result<(Vec<u8>, u64), FetchError> {
    let mut response = client
        .get(url)
        .header(header::RANGE, "bytes=0-0")
        .header(header::ACCEPT_ENCODING, "identity")
        .timeout(PROBE_TIMEOUT)
        .send()
        .map_err(|error| FetchError::from_reqwest(&error))?;
    let status = response.status().as_u16();
    if status != 206 {
        if CAPTURE_ERROR_BODY {
            // 只读前 256 字节：错误页可能是一整页 HTML，没必要为诊断把整个
            // body 拖下来。`&mut` 借出去，response 留在原地。
            let mut buf = Vec::new();
            let _ = (&mut response).take(256).read_to_end(&mut buf);
            let body = String::from_utf8_lossy(&buf).into_owned();
            if !body.is_empty() {
                eprintln!("取流失败 status={status} body={}", body_snippet(&body));
            }
        }
        return Err(FetchError::Status(status));
    }
    let (start, end, total) = response
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .and_then(content_range)
        .ok_or(FetchError::Protocol)?;
    if start != 0 || end != 0 {
        return Err(FetchError::Protocol);
    }
    Ok((Vec::new(), total))
}

/// TEMP(error-body)：一次性诊断开关。实测定点（2026-10-24，Air）里 CDN 对
/// 35% 的取流请求返 403，且与地址来源、地址年龄都无关 —— 是每次请求独立被拒。
/// 只有状态码看不出被拒的理由，这里把响应体前 128 个字符一起报上去。
///
/// 撤的方式：置 false 即回到「只有 status」；彻底删除时连同 `body_snippet`
/// 和 `Source::open` 里引用它的那几行一起去掉。
const CAPTURE_ERROR_BODY: bool = true;

/// 错误响应体只留前 128 个字符，控制字符（含换行）换成空格 —— 日志是按行读的，
/// 一段带换行的 HTML 会把后续记录冲散。
fn body_snippet(body: &str) -> String {
    let mut out = String::new();
    for ch in body.chars().take(128) {
        out.push(if ch.is_control() { ' ' } else { ch });
    }
    let trimmed = out.trim();
    // 有些 CDN 会把请求的完整地址回显在错误页里，而签名就在 query 上。见到
    // `http` 就只保留它之前的部分，不把带签名的地址写进日志。
    match trimmed.find("http") {
        Some(index) => trimmed[..index].trim_end().to_string(),
        None => trimmed.to_string(),
    }
}

struct Source {
    file: Option<File>,
    client: Option<&'static Client>,
    url: String,
    size: u64,
    cache_start: u64,
    cache: Vec<u8>,
    /// Set when the session closes, so a stalled read stops retrying.
    cancelled: Arc<AtomicBool>,
    /// The last network failure, kept for classifying a failed decrypt open.
    last_error: Arc<Mutex<Option<FetchError>>>,
}
impl Source {
    fn open(url: String) -> Result<Self, OpenError> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let file = if url.starts_with("file:") {
            let path = url::Url::parse(&url)
                .map_err(|_| OpenError::new("离线文件地址无效", "file"))?
                .to_file_path()
                .map_err(|_| OpenError::new("离线文件地址无效", "file"))?;
            Some(File::open(path).map_err(|_| OpenError::new("离线文件不存在或无法读取", "file"))?)
        } else if !url.starts_with("https://") && !url.starts_with("http://") {
            Some(File::open(&url).map_err(|_| OpenError::new("离线文件不存在或无法读取", "file"))?)
        } else {
            None
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        let (client, size) = if let Some(file) = &file {
            let size = file
                .metadata()
                .map_err(|_| OpenError::new("无法读取文件长度", "file"))?
                .len();
            (None, size)
        } else {
            let client = media_client(&url)?;
            let (_, total) =
                with_retries(&cancelled, || probe(client, &url)).map_err(OpenError::fetch)?;
            (Some(client), total)
        };
        if size == 0 || size > i64::MAX as u64 {
            return Err(OpenError::new("媒体文件长度无效", "range"));
        }
        Ok(Self {
            file,
            client,
            url,
            size,
            cache_start: 0,
            cache: Vec::new(),
            cancelled,
            last_error: Arc::default(),
        })
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(());
        }
        if offset >= self.size {
            return Ok(0);
        }
        if let Some(file) = &mut self.file {
            file.seek(SeekFrom::Start(offset)).map_err(|_| ())?;
            return file.read(bytes).map_err(|_| ());
        }
        let cache_end = self
            .cache_start
            .checked_add(self.cache.len() as u64)
            .ok_or(())?;
        if offset < self.cache_start || offset >= cache_end {
            let end = offset
                .checked_add(1024 * 1024 - 1)
                .ok_or(())?
                .min(self.size - 1);
            let client = self.client.ok_or(())?;
            let result = with_retries(&self.cancelled, || {
                fetch_known_range(client, &self.url, offset, end, CHUNK_TIMEOUT, self.size)
            });
            let data = match result {
                Ok(data) => data,
                Err(error) => {
                    if let Ok(mut last) = self.last_error.lock() {
                        *last = Some(error);
                    }
                    return Err(());
                }
            };
            self.cache_start = offset;
            self.cache = data;
        }
        let start =
            usize::try_from(offset.checked_sub(self.cache_start).ok_or(())?).map_err(|_| ())?;
        let count = bytes
            .len()
            .min(self.cache.len().checked_sub(start).ok_or(())?);
        bytes[..count].copy_from_slice(&self.cache[start..start + count]);
        Ok(count)
    }
}
extern "C" fn io_size(user: *mut c_void) -> i64 {
    unsafe { (*(user as *mut Source)).size as i64 }
}
extern "C" fn io_read(user: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> isize {
    std::panic::catch_unwind(|| unsafe {
        let source = &mut *(user as *mut Source);
        source
            .read_at(offset, std::slice::from_raw_parts_mut(buffer, length))
            .map(|n| n as isize)
            .unwrap_or(-1)
    })
    .unwrap_or(-1)
}
// sp_stream calls this on every seek to abandon the old position, so it must
// not end the source; closing the session sets `Source::cancelled` instead.
extern "C" fn io_cancel(_: *mut c_void) {}
extern "C" fn io_close(user: *mut c_void) {
    unsafe {
        drop(Box::from_raw(user as *mut Source));
    }
}

enum Reader {
    Clear(Box<Source>),
    Encrypted(*mut c_void),
}
// Every operation, including Drop, is protected by the session mutex.
unsafe impl Send for Reader {}
impl Drop for Reader {
    fn drop(&mut self) {
        if let Self::Encrypted(stream) = self {
            unsafe {
                sp_stream_close(*stream);
            }
        }
    }
}
impl Reader {
    fn size(&self) -> u64 {
        match self {
            Self::Clear(source) => source.size,
            Self::Encrypted(stream) => unsafe { sp_stream_size(*stream) as u64 },
        }
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        match self {
            Self::Clear(source) => source.read_at(offset, bytes),
            Self::Encrypted(stream) => unsafe {
                let mut error = SpError {
                    code: 0,
                    message: [0; 192],
                };
                if sp_stream_seek(*stream, offset as i64, &mut error) < 0 {
                    return Err(());
                }
                let n = sp_stream_read(*stream, bytes.as_mut_ptr(), bytes.len(), &mut error);
                if n < 0 {
                    Err(())
                } else {
                    Ok(n as usize)
                }
            },
        }
    }
}
struct Session {
    reader: Mutex<Reader>,
    stop: AtomicBool,
    /// Shared with the network source: closing ends its pending retries.
    cancelled: Option<Arc<AtomicBool>>,
    size: u64,
    authority: String,
    path: String,
    sockets: Mutex<SocketRegistry>,
}

#[derive(Default)]
struct SocketRegistry {
    stopped: bool,
    next_id: u64,
    sockets: HashMap<u64, TcpStream>,
}

static ACTIVE_SOCKETS: AtomicUsize = AtomicUsize::new(0);

struct SocketAdmission {
    session: Arc<Session>,
    id: u64,
}

impl SocketAdmission {
    fn register(session: Arc<Session>, socket: &TcpStream) -> Option<Self> {
        let clone = socket.try_clone().ok()?;
        let mut registry = session
            .sockets
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if registry.stopped || registry.sockets.len() >= 8 {
            return None;
        }
        let id = registry.next_id.checked_add(1)?;
        ACTIVE_SOCKETS
            .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 32).then_some(count + 1)
            })
            .ok()?;
        registry.next_id = id;
        registry.sockets.insert(id, clone);
        drop(registry);
        Some(Self { session, id })
    }
}

impl Drop for SocketAdmission {
    fn drop(&mut self) {
        self.session
            .sockets
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .sockets
            .remove(&self.id);
        ACTIVE_SOCKETS.fetch_sub(1, Ordering::AcqRel);
    }
}

impl Session {
    fn close(&self) {
        let sockets = {
            let mut registry = self
                .sockets
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            registry.stopped = true;
            self.stop.store(true, Ordering::Release);
            if let Some(cancelled) = &self.cancelled {
                cancelled.store(true, Ordering::Release);
            }
            std::mem::take(&mut registry.sockets)
        };
        for socket in sockets.into_values() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}
static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Session>>>> = OnceLock::new();
fn sessions() -> &'static Mutex<HashMap<String, Arc<Session>>> {
    SESSIONS.get_or_init(Default::default)
}

fn parse_range(header: Option<&str>, size: u64) -> Result<(u64, u64, bool), ()> {
    let Some(value) = header else {
        return Ok((0, size - 1, false));
    };
    let (start, end) = value
        .strip_prefix("bytes=")
        .ok_or(())?
        .split_once('-')
        .ok_or(())?;
    if end.contains(',') {
        return Err(());
    }
    let (start, end) = if start.is_empty() {
        let suffix: u64 = end.parse().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        (size.saturating_sub(suffix), size - 1)
    } else {
        (
            start.parse::<u64>().map_err(|_| ())?,
            if end.is_empty() {
                size - 1
            } else {
                end.parse::<u64>().map_err(|_| ())?.min(size - 1)
            },
        )
    };
    if start > end || start >= size {
        return Err(());
    }
    Ok((start, end, true))
}
fn serve(mut socket: TcpStream, session: Arc<Session>) -> std::io::Result<()> {
    // Winsock can inherit FIONBIO from the nonblocking listener. Accepted
    // connections are handled by dedicated workers and must perform blocking
    // reads; otherwise a partially arrived HTTP header is mistaken for EOF.
    socket.set_nonblocking(false)?;
    socket.set_write_timeout(Some(Duration::from_secs(3)))?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || session.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        socket.set_read_timeout(Some(remaining))?;
        let mut byte = [0];
        if request.len() >= 16384 || socket.read(&mut byte)? == 0 {
            return Ok(());
        }
        request.push(byte[0]);
    }
    let request = String::from_utf8_lossy(&request);
    let mut lines = request.split("\r\n");
    let first: Vec<_> = lines.next().unwrap_or("").split_whitespace().collect();
    let mut host = None;
    let mut range = None;
    let mut origin = false;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "host" => host = Some(value.trim()),
                "range" => range = Some(value.trim()),
                "origin" => origin = true,
                _ => (),
            }
        }
    }
    if first.len() != 3
        || !matches!(first[0], "GET" | "HEAD")
        || first[1] != session.path
        || host != Some(session.authority.as_str())
        || origin
        || session.stop.load(Ordering::Acquire)
    {
        return socket.write_all(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    }
    let (mut position, end, partial) = match parse_range(range, session.size) {
        Ok(range) => range,
        Err(_) => return write!(socket, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", session.size),
    };
    let status = if partial {
        "206 Partial Content"
    } else {
        "200 OK"
    };
    write!(socket, "HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n", end - position + 1)?;
    if partial {
        write!(
            socket,
            "Content-Range: bytes {position}-{end}/{}\r\n",
            session.size
        )?;
    }
    socket.write_all(b"\r\n")?;
    if first[0] == "HEAD" {
        return Ok(());
    }
    let mut bytes = vec![0; 64 * 1024];
    while position <= end && !session.stop.load(Ordering::Acquire) {
        let count = (bytes.len() as u64).min(end - position + 1) as usize;
        let n = session
            .reader
            .lock()
            .map_err(|_| std::io::Error::other("media lock"))?
            .read_at(position, &mut bytes[..count])
            .map_err(|_| std::io::Error::other("media read"))?;
        if n == 0 {
            return Err(std::io::Error::other("unexpected media EOF"));
        }
        if session.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        socket.write_all(&bytes[..n])?;
        position = position
            .checked_add(n as u64)
            .ok_or_else(|| std::io::Error::other("media offset"))?;
    }
    Ok(())
}
#[derive(Deserialize)]
struct OpenRequest {
    url: String,
    #[serde(default)]
    key: String,
}
fn open(request: OpenRequest) -> Result<serde_json::Value, OpenError> {
    let source = Box::new(Source::open(request.url)?);
    let cancelled = source.client.map(|_| source.cancelled.clone());
    let last_error = source.last_error.clone();
    let reader = if request.key.is_empty() {
        Reader::Clear(source)
    } else {
        let key =
            hex::decode(&request.key).map_err(|_| OpenError::new("媒体密钥无效", "decrypt"))?;
        if key.len() != 16 {
            return Err(OpenError::new("媒体密钥无效", "decrypt"));
        }
        let user = Box::into_raw(source) as *mut c_void;
        let io = SpIo {
            user,
            size: io_size,
            read_at: io_read,
            cancel: io_cancel,
            close: io_close,
        };
        let mut error = SpError {
            code: 0,
            message: [0; 192],
        };
        let stream = unsafe { sp_stream_open(&io, key.as_ptr(), &mut error) };
        if stream.is_null() {
            io_close(user);
            // The header is read through the network source: a failed read
            // there is a network problem, not a broken file.
            let fetch = last_error.lock().ok().and_then(|last| *last);
            return Err(match fetch {
                Some(error) => OpenError::fetch(error),
                None => OpenError::new("无法打开加密媒体，请重试或切换清晰度", "decrypt"),
            });
        }
        Reader::Encrypted(stream)
    };
    let local = |message| move |_| OpenError::new(message, "other");
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(local("无法打开本机媒体端口"))?;
    listener
        .set_nonblocking(true)
        .map_err(local("无法初始化媒体端口"))?;
    let authority = listener
        .local_addr()
        .map_err(local("媒体端口不可用"))?
        .to_string();
    let token = hex::encode(rand::random::<[u8; 32]>());
    let path = format!("/media/{token}");
    let url = format!("http://{authority}{path}");
    let session = Arc::new(Session {
        size: reader.size(),
        reader: Mutex::new(reader),
        stop: AtomicBool::new(false),
        cancelled,
        authority,
        path,
        sockets: Mutex::default(),
    });
    sessions()
        .lock()
        .map_err(|_| OpenError::new("媒体会话不可用", "other"))?
        .insert(token.clone(), session.clone());
    let listener_session = session.clone();
    if thread::Builder::new()
        .name("media-listener".into())
        .spawn(move || {
            let session = listener_session;
            while !session.stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((socket, address)) if address.ip().is_loopback() => {
                        if let Some(admission) = SocketAdmission::register(session.clone(), &socket)
                        {
                            let _ = thread::Builder::new().name("media-socket".into()).spawn(
                                move || {
                                    let _ = serve(socket, admission.session.clone());
                                    drop(admission);
                                },
                            );
                        }
                    }
                    Ok(_) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => break,
                }
            }
        })
        .is_err()
    {
        session.close();
        if let Ok(mut sessions) = sessions().lock() {
            sessions.remove(&token);
        }
        return Err(OpenError::new("无法启动媒体端口", "other"));
    }
    Ok(serde_json::json!({"id": token, "url": url}))
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_open(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() {
            return Err(OpenError::new("媒体请求无效", "other"));
        }
        let request: OpenRequest = serde_json::from_slice(CStr::from_ptr(request).to_bytes())
            .map_err(|_| OpenError::new("媒体请求无效", "other"))?;
        open(request)
    })
    .unwrap_or_else(|_| Err(OpenError::new("媒体初始化失败", "other")));
    let value = match result {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "error": error.message,
            "kind": error.kind,
            "status": error.status,
        }),
    };
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_close(id: *const c_char) {
    if id.is_null() {
        return;
    }
    if let Ok(id) = CStr::from_ptr(id).to_str() {
        let session = sessions()
            .lock()
            .ok()
            .and_then(|mut sessions| sessions.remove(id));
        if let Some(session) = session {
            session.close();
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn media_addresses_prefer_ipv4() {
        let v4a: SocketAddr = "115.231.82.94:443".parse().unwrap();
        let v4b: SocketAddr = "183.131.46.68:443".parse().unwrap();
        let v6a: SocketAddr = "[240e:f7:a096:20e::52]:443".parse().unwrap();
        let v6b: SocketAddr = "[240e:970:4020:13::61]:443".parse().unwrap();
        assert_eq!(
            ipv4_first(vec![v6a, v4a, v6b, v4b]),
            vec![v4a, v4b, v6a, v6b]
        );
        // A host without A records keeps its address list untouched.
        assert_eq!(ipv4_first(vec![v6a, v6b]), vec![v6a, v6b]);
        assert!(ipv4_first(Vec::new()).is_empty());
    }
    #[test]
    fn range_contract() {
        assert_eq!(parse_range(None, 100), Ok((0, 99, false)));
        assert_eq!(parse_range(Some("bytes=10-19"), 100), Ok((10, 19, true)));
        assert_eq!(parse_range(Some("bytes=90-"), 100), Ok((90, 99, true)));
        assert_eq!(parse_range(Some("bytes=-8"), 100), Ok((92, 99, true)));
        for bad in ["bytes=100-", "bytes=9-2", "bytes=0-1,4-5", "bytes=-0"] {
            assert!(parse_range(Some(bad), 100).is_err());
        }
    }
}
