import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/l10n/strings.dart';

void main() {
  testWidgets('English localization loads', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: [AppStrings.delegate],
        home: Builder(builder: _LocalizedLabel.new),
      ),
    );
    expect(find.text('Workspace'), findsOneWidget);
  });

  test('Simplified Chinese covers the settings and batch helper text', () {
    const strings = AppStrings(Locale('zh', 'CN'));

    expect(strings.t('context_terms_hint'), '产品名称、人名、缩写…');
    expect(strings.t('automatic'), '自动识别');
    expect(strings.t('none'), '无');
    expect(strings.t('delete_history'), '从资料库移除');
    expect(strings.t('remove_podcast_title'), '移除播客项目？');
    expect(strings.t('remove_podcast_body'), contains('从“已下载”和“资料库”中移除'));
    expect(strings.t('remove_podcast_body'), contains('播放进度会保留'));
    expect(
      strings.t('auto_transcribe_local_description'),
      contains('拖入收件箱的文件仍需手动'),
    );
    expect(strings.t('notices'), '第三方声明');
    expect(strings.t('notices_body'), contains('第三方转写服务提供商'));
    expect(strings.error('bad_credentials'), 'Soniox API 密钥无效。');
    expect(
      strings.error('organization_balance_exhausted'),
      'Soniox 账户余额不足。请先在 Soniox 控制台充值，然后重新转写。',
    );
    expect(
      strings.error('project_monthly_budget_exhausted'),
      'Soniox 每月预算已用完。请在 Soniox 控制台提高组织或项目预算，然后重新转写。',
    );
    expect(strings.speakerName('Speaker 2'), '说话人 2');
  });

  test('English and Simplified Chinese localization keys stay in parity', () {
    expect(AppStrings.missingChineseKeys, isEmpty);
    expect(AppStrings.unexpectedChineseKeys, isEmpty);
  });
}

class _LocalizedLabel extends StatelessWidget {
  const _LocalizedLabel(this.context);
  final BuildContext context;

  @override
  Widget build(BuildContext context) =>
      Text(AppStrings.of(context).t('workspace'));
}
