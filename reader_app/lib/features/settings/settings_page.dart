import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../services/scoring/ise_credentials.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/xfyun_ise_provider.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _appId = TextEditingController();
  final _apiKey = TextEditingController();
  final _apiSecret = TextEditingController();
  var _loading = true;
  var _saving = false;
  var _testing = false;
  var _showSecret = false;
  String? _status;
  bool? _statusOk;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _appId.dispose();
    _apiKey.dispose();
    _apiSecret.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await ref.read(iseCredentialStoreProvider).read();
      if (!mounted) return;
      if (value != null) {
        _appId.text = value.appId;
        _apiKey.text = value.apiKey;
        _apiSecret.text = value.apiSecret;
      }
    } on Object {
      if (mounted) {
        _status = '暂时无法读取已保存的配置';
        _statusOk = false;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  IseCredentials get _credentials => IseCredentials(
        appId: _appId.text,
        apiKey: _apiKey.text,
        apiSecret: _apiSecret.text,
      ).normalized();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      await ref.read(iseCredentialStoreProvider).write(_credentials);
      if (!mounted) return;
      setState(() {
        _status = '讯飞配置已安全保存';
        _statusOk = true;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _status = '配置没有保存，请稍后重试';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _status = '正在连接讯飞评分服务…';
      _statusOk = null;
    });
    try {
      await ref.read(iseConnectionProbeProvider).testCredentials(_credentials);
      if (!mounted) return;
      setState(() {
        _status = '连接成功，可以开始跟读评分';
        _statusOk = true;
      });
    } on ScoringException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.message;
        _statusOk = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _status = '连接没有完成，请稍后重试';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _clear() async {
    await ref.read(iseCredentialStoreProvider).clear();
    if (!mounted) return;
    setState(() {
      _appId.clear();
      _apiKey.clear();
      _apiSecret.clear();
      _status = '已清除讯飞配置';
      _statusOk = true;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/shelf'),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回书架',
          ),
          title: const Text('设置'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.pageMargin),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _RecordingManagementCard(),
                            const SizedBox(height: AppSpacing.pageMargin),
                            _buildIseCard(context),
                            const SizedBox(height: AppSpacing.pageMargin),
                            _AboutCard(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      );

  Widget _buildIseCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.mic_outlined, color: AppColors.primary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.cardPadding),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '讯飞跟读评分',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const Text(
                          '凭据只保存在本机安全存储中，不会写入绘本或日志。',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.pageMargin),
              TextFormField(
                key: const ValueKey('settings-app-id'),
                controller: _appId,
                decoration: const InputDecoration(labelText: 'AppID'),
                textInputAction: TextInputAction.next,
                validator: _required,
              ),
              const SizedBox(height: AppSpacing.cardPadding),
              TextFormField(
                key: const ValueKey('settings-api-key'),
                controller: _apiKey,
                decoration: const InputDecoration(labelText: 'APIKey'),
                textInputAction: TextInputAction.next,
                validator: _required,
              ),
              const SizedBox(height: AppSpacing.cardPadding),
              TextFormField(
                key: const ValueKey('settings-api-secret'),
                controller: _apiSecret,
                obscureText: !_showSecret,
                decoration: InputDecoration(
                  labelText: 'APISecret',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _showSecret = !_showSecret),
                    icon: Icon(
                      _showSecret ? Icons.visibility_off : Icons.visibility,
                    ),
                    tooltip: _showSecret ? '隐藏 APISecret' : '显示 APISecret',
                  ),
                ),
                validator: _required,
              ),
              if (_status != null) ...[
                const SizedBox(height: AppSpacing.cardPadding),
                _SettingsStatus(message: _status!, ok: _statusOk),
              ],
              const SizedBox(height: AppSpacing.pageMargin),
              Wrap(
                spacing: AppSpacing.unit,
                runSpacing: AppSpacing.unit,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving || _testing ? null : _clear,
                    child: const Text('清除配置'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('settings-test-connection'),
                    onPressed: _saving || _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: const Text('测试连接'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('settings-save'),
                    onPressed: _saving || _testing ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.bgAlt,
                            ),
                          )
                        : const Icon(Icons.lock_outline),
                    label: const Text('安全保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

String? _required(String? value) =>
    value == null || value.trim().isEmpty ? '请填写这一项' : null;

class _SettingsStatus extends StatelessWidget {
  const _SettingsStatus({required this.message, required this.ok});

  final String message;
  final bool? ok;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: ok == false
              ? AppColors.danger.withOpacity(0.08)
              : AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          child: Row(
            children: [
              Icon(
                ok == false
                    ? Icons.error_outline
                    : ok == true
                        ? Icons.check_circle_outline
                        : Icons.hourglass_top,
                color: ok == false ? AppColors.danger : AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.unit),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '关于 ReadAlong',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.unit),
              const Text('版本 0.1.2 · 支持资源包 schema v1'),
              const SizedBox(height: AppSpacing.unit),
              const Text(
                '离线混音使用 FFmpegKit（LGPL-3.0）；完整开源许可随应用提供。',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'ReadAlong 跟读宝',
                    applicationVersion: '0.1.2',
                  ),
                  child: const Text('查看开源许可'),
                ),
              ),
            ],
          ),
        ),
      );
}

class _RecordingManagementCard extends StatelessWidget {
  const _RecordingManagementCard();

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: const ValueKey('settings-recording-management'),
          minVerticalPadding: AppSpacing.cardPadding,
          leading: const SizedBox(
            width: 48,
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accentContainer,
                shape: BoxShape.circle,
              ),
              child:
                  Icon(Icons.library_music_outlined, color: AppColors.accent),
            ),
          ),
          title: const Text(
            '录音与作品',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text('查看并批量删除逐句录音、完整录音和已生成作品'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/recordings'),
        ),
      );
}
