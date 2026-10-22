import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_log.dart';
import '../services/secret_store.dart';
import '../services/webdav_client.dart';
import '../services/webdav_config.dart';
import '../services/webdav_sync_service.dart';
import '../widgets/home/home_design.dart';

/// WebDAV 双向同步：地址与账号存在本页，密码经系统密钥库加密后落地。
///
/// 合并规则复用「备份与恢复」那一套（进度双闸门、阅读时长按天取大、收藏与
/// 已看取并集），本页只负责配置与触发，见 `WebdavSyncService` 的类注释。
class WebdavSyncPage extends StatefulWidget {
  const WebdavSyncPage({super.key, this.service});

  /// Injectable so a widget test can drive the sync without a server.
  final WebdavSyncService? service;

  @override
  State<WebdavSyncPage> createState() => _WebdavSyncPageState();
}

class _WebdavSyncPageState extends State<WebdavSyncPage> {
  final _configStore = WebdavConfigStore.instance;
  final _secrets = SecretStore.instance;
  late final WebdavSyncService _service = widget.service ?? WebdavSyncService();

  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _fileName = TextEditingController(text: WebdavConfig.defaultFileName);

  bool _loading = true;
  bool _obscure = true;
  String? _busy;
  String? _message;

  /// 上一次失败的操作。只在「失败的性质是等一等可能就好」时留着，页面据此
  /// 多给一个「重试」；认证失败、超过上限这类不给，因为再点一次结果一样。
  Future<void> Function()? _retry;
  DateTime? _lastSyncedAt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // 复用连接的 service 是这页自己造的（测试注入的那个不属于它，但 close
    // 只放连接、下次用会重建，所以两种情况都安全）。
    _service.close();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _fileName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await _configStore.load();
    final lastSyncedAt = await _configStore.lastSyncedAt();
    String? password;
    String? secretMessage;
    try {
      password = await _secrets.read(SecretStore.webdavPassword);
    } on SecretStoreException catch (error) {
      // The stored secret cannot be recovered, so it is dropped and the field
      // stays empty: syncing then asks for the password instead of sending a
      // wrong one and surfacing a confusing authentication failure.
      await _secrets.delete(SecretStore.webdavPassword);
      secretMessage = error.message;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _lastSyncedAt = lastSyncedAt;
      _message = secretMessage;
      if (config != null) {
        _url.text = config.collectionUrl;
        _user.text = config.username;
        _fileName.text = config.fileName;
      }
      if (password != null) _password.text = password;
    });
  }

  /// Validates and stores the form. Null means the message was set instead.
  Future<WebdavConfig?> _persist() async {
    final urlError = validateWebdavUrl(_url.text);
    if (urlError != null) {
      setState(() => _message = urlError);
      return null;
    }
    final nameError = validateWebdavFileName(_fileName.text);
    if (nameError != null) {
      setState(() => _message = nameError);
      return null;
    }
    final config = WebdavConfig(
      collectionUrl: normalizeWebdavUrl(_url.text),
      username: _user.text.trim(),
      fileName: _fileName.text.trim(),
    );
    await _configStore.save(config);
    await _secrets.write(SecretStore.webdavPassword, _password.text);
    if (mounted) {
      // Show what was stored, including the slash that was added for the user.
      setState(() {
        _url.text = config.collectionUrl;
        _fileName.text = config.fileName;
      });
    }
    return config;
  }

  Future<void> _save() => _run('正在保存配置…', () async {
    final config = await _persist();
    if (config == null || !mounted) return;
    setState(() {
      _message = '已保存，密码经系统密钥库加密后存放在本机。';
    });
  });

  Future<void> _sync() => _run('正在同步，请不要退出页面…', () async {
    final config = await _persist();
    if (config == null) return;
    final report = await _service.sync(config, password: _password.text);
    final finishedAt = DateTime.now();
    await _configStore.markSynced(finishedAt);
    if (!mounted) return;
    setState(() {
      _lastSyncedAt = finishedAt;
      _message = describeSyncReport(report);
    });
  });

  /// 云端文件坏掉时的最后出口：不问云端有什么，直接用本机数据替换。
  ///
  /// 自动回退（`.bak`）能救回「刚传坏一次」；救不回「主文件和 .bak 都读不懂」。
  /// 那种情况以前只能去网盘网页端手动删文件，而这个按钮把出口留在应用里。
  Future<void> _overwrite() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('用本机数据覆盖云端？'),
        content: const Text(
          '云端的备份文件会被本机当前的数据替换，原文件保留为 .bak 可随时取回。\n\n'
          '另一台设备的进度如果还没合并到本机，会因此丢失。'
          '只在云端文件损坏、同步一直失败时才这样做。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run('正在用本机数据覆盖云端…', () async {
      final config = await _persist();
      if (config == null) return;
      final report = await _service.overwriteRemote(
        config,
        password: _password.text,
      );
      final finishedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _lastSyncedAt = finishedAt;
        _message =
            '已用本机数据覆盖云端（${(report.uploadedBytes / 1024).toStringAsFixed(1)} KB），'
            '原文件保留为 .bak。';
      });
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除本机的 WebDAV 配置？'),
        content: const Text('只清除本机保存的地址、账号、密码和同步记录，云端的备份文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _configStore.clear();
    await _secrets.delete(SecretStore.webdavPassword);
    if (!mounted) return;
    setState(() {
      _url.clear();
      _user.clear();
      _password.clear();
      _fileName.text = WebdavConfig.defaultFileName;
      _lastSyncedAt = null;
      _message = '已清除本机配置，云端备份文件保持原样。';
    });
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _message = null;
      _retry = null;
    });
    try {
      await action();
    } on SecretStoreException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on WebdavException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message;
        // 「重试」只在值得重试时出现 —— 401 或超过上限时摆一个按钮在那里，
        // 点下去只会得到一模一样的结果。
        _retry = error.canRetry ? () => _run(label, action) : null;
      });
    } on StateError catch (error) {
      if (mounted) setState(() => _message = '本机数据尚未就绪：${error.message}');
    } catch (error, stack) {
      // Anything else is unexpected, so it goes to the log the settings page
      // can export instead of disappearing into a generic message.
      AppLog.w('webdav-sync', '同步失败', error: error, stack: stack);
      if (mounted) {
        setState(() {
          _message = '操作未完成，请检查地址、账号和网络后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Shown under the address field. What gets stored is a folder URL and the
  /// snapshot is created inside it, so an address that is the WebDAV root is
  /// exactly the shape several cloud drives refuse: Nutstore answers 404 for a
  /// PUT there, which reads like a wrong path rather than a rule of the drive.
  static const _folderNote =
      '地址要指向一个已存在的文件夹：有的网盘（如坚果云）不允许在根目录下新建文件，'
      '需要先在网页端建一个文件夹，再把地址填成这个文件夹。';

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final busy = _busy != null;
    final lastSyncedAt = _lastSyncedAt
        ?.toLocal()
        .toString()
        .split('.')
        .first;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: palette.canvas,
        appBar: AppBar(
          title: const Text('WebDAV 同步'),
          centerTitle: true,
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _section(palette, [
                    Text(
                      '两台手机，用同一个云端目录对齐',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '同步收藏、阅读/播放进度、已看剧集、阅读时长和搜索历史，'
                      '与「备份与恢复」导出的文件是同一份数据。',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '同步时先合并云端，再把合并结果写回云端。同一作品保留记录时间较新、'
                      '且读得更靠后的一条，进度不会回退。',
                      style: TextStyle(color: palette.muted),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '收藏的增删也会同步：在一台手机上移除的收藏，另一台同步后会一起消失；'
                      '若那台在之后又重新加回，以加回的那次为准。',
                      style: TextStyle(color: palette.muted),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '两台设备都要各点一次「立即同步」。密码用系统密钥库加密后仅存本机，'
                      '不会写进云端文件。',
                      style: TextStyle(color: palette.muted),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  _section(palette, [
                    Text(
                      '服务器',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _field(
                      palette,
                      controller: _url,
                      label: 'WebDAV 目录地址',
                      hint: 'https://dav.example.com/dav/我的目录/',
                      keyboardType: TextInputType.url,
                    ),
                    _field(
                      palette,
                      controller: _user,
                      label: '用户名',
                      hint: '没有账号可留空',
                    ),
                    _field(
                      palette,
                      controller: _password,
                      label: '密码',
                      obscure: _obscure,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                          size: 20,
                          color: palette.muted,
                        ),
                        tooltip: _obscure ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    _field(
                      palette,
                      controller: _fileName,
                      label: '云端文件名',
                      hint: WebdavConfig.defaultFileName,
                    ),
                    // Listens to the field so the note follows what is typed,
                    // not only the value restored from storage.
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _url,
                      builder: (context, value, _) => Text(
                        '${value.text.trim().startsWith('http://')
                            ? '当前使用明文 http：家庭内网可以用，公共网络下建议换成 https。'
                            : '用 https 地址时凭据是加密传输的；地址末尾的 / 会自动补上。'}'
                        '$_folderNote',
                        style: TextStyle(color: palette.muted, fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: busy || _loading ? null : _save,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('保存配置'),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  _section(palette, [
                    Text(
                      '同步',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      lastSyncedAt == null
                          ? '本机还没有成功同步过。'
                          : '上次同步：$lastSyncedAt',
                      style: TextStyle(color: palette.muted),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: busy || _loading ? null : _sync,
                      icon: const Icon(Icons.cloud_sync),
                      label: const Text('立即同步'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: busy || _loading ? null : _overwrite,
                      icon: Icon(Icons.upload_file, color: palette.muted),
                      label: Text(
                        '用本机覆盖云端',
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: busy ? null : _clear,
                      icon: Icon(Icons.delete_outline, color: palette.muted),
                      label: Text(
                        '清除本机配置',
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                  ]),
                  if (_busy case final label?) ...[
                    const SizedBox(height: 16),
                    Semantics(liveRegion: true, child: Text(label)),
                  ],
                  if (_message case final message?) ...[
                    const SizedBox(height: 16),
                    _section(palette, [
                      Semantics(liveRegion: true, child: Text(message)),
                      if (_retry case final retry?) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _busy == null ? retry : null,
                            child: const Text('重试'),
                          ),
                        ),
                      ],
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    HomePalette palette, {
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    Widget? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      // Flutter 会把「autocorrect 与 suggestions 都关掉的普通文本框」映射成
      // Android 的 TYPE_TEXT_VARIATION_VISIBLE_PASSWORD，输入法据此判定为密码框、
      // 切到系统安全键盘。所以这里显式声明键盘类型，联想也只对真正的密码框关闭。
      keyboardType: keyboardType ?? TextInputType.text,
      // 这一页是「服务器地址 + 账号」，不是登录表单：把自动填充提示显式置空，
      // 否则 Android 会把地址/用户名/密码当成一组凭据，给每个框都弹密码建议。
      autofillHints: const <String>[],
      // Disabled until the stored configuration has been read, so a keystroke
      // cannot be overwritten by the values arriving from storage.
      enabled: _busy == null && !_loading,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: TextStyle(fontSize: 14.5, color: palette.ink),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        isDense: true,
        labelStyle: TextStyle(color: palette.muted),
        hintStyle: TextStyle(color: palette.muted, fontSize: 13),
        enabledBorder: _fieldBorder(palette.line),
        disabledBorder: _fieldBorder(palette.line),
        focusedBorder: _fieldBorder(HomePalette.accent),
      ),
    ),
  );

  static OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color),
  );

  Widget _section(HomePalette palette, List<Widget> children) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: palette.line),
    ),
    child: DefaultTextStyle.merge(
      style: TextStyle(color: palette.ink, height: 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
