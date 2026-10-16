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
  DateTime? _lastSyncedAt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
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
      _message = _describe(report);
    });
  });

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
    });
    try {
      await action();
    } on SecretStoreException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on WebdavException catch (error) {
      if (mounted) setState(() => _message = error.message);
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

  static String _describe(WebdavSyncReport report) {
    final counts =
        '收藏 ${report.shelf} 条、进度 ${report.history} 条、'
        '已看 ${report.episodes} 集、阅读时长 ${report.readTime} 项、'
        '搜索历史 ${report.searchHistory} 条';
    final size = '${(report.uploadedBytes / 1024).toStringAsFixed(1)} KB';
    if (!report.remoteExisted) {
      return '云端还没有备份文件，已把本机数据上传（$counts，共 $size）。'
          '在另一台手机打开本页点「立即同步」即可拿到这些数据。';
    }
    return '已从云端合并：$counts；并把合并后的结果（$size）写回云端。'
        '同一作品保留读得更靠后的进度，收藏与已看取并集。';
  }

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
                      '只合并不删除：在一台手机上移除的收藏，会被另一台手机同步回来。'
                      '需要彻底清理时，请先在两端都删掉再同步。',
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
                        value.text.trim().startsWith('http://')
                            ? '当前使用明文 http：家庭内网可以用，公共网络下建议换成 https。'
                            : '用 https 地址时凭据是加密传输的；地址末尾的 / 会自动补上。',
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
    Widget? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      // Disabled until the stored configuration has been read, so a keystroke
      // cannot be overwritten by the values arriving from storage.
      enabled: _busy == null && !_loading,
      autocorrect: false,
      enableSuggestions: false,
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
