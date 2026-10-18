import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/auth/login_region_check.dart';
import '../widgets/settings_section.dart';

/// 网络地区检测：开关整个检测、网络变动时是否复查、以及本次打开临时跳过。
///
/// 检测在登录页与播放起播前共用（见 [LoginRegionCheck] / PlaybackRegionGate）：
/// 出口在中国大陆就不加载登录页、也不开始播放。
class RegionCheckSection extends StatefulWidget {
  const RegionCheckSection({super.key});

  @override
  State<RegionCheckSection> createState() => _RegionCheckSectionState();
}

class _RegionCheckSectionState extends State<RegionCheckSection> {
  void _update(PreferencesProvider provider, {bool? enabled, bool? onNetwork}) {
    provider.update(
      provider.prefs.copyWith(
        regionCheckEnabled: enabled,
        regionCheckOnNetworkChange: onNetwork,
      ),
    );
    if (enabled != null) {
      context.read<PlaybackProvider?>()?.regionGate?.reset();
    }
    setState(() {});
  }

  /// 「本次打开跳过」只活在内存里：重启后 [LoginRegionCheck.skippedThisRun] 自然回到 false。
  void _skipThisRun() {
    LoginRegionCheck.skipForThisRun();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final provider = context.watch<PreferencesProvider>();
    final prefs = provider.prefs;
    final enabled = prefs.regionCheckEnabled;
    final skipped = LoginRegionCheck.skippedThisRun;
    return SettingsSection(
      title: l10n.regionCheckSectionTitle,
      footer: l10n.regionCheckSectionSubtitle,
      children: [
        SettingsSwitchTile(
          title: l10n.regionCheckEnabled,
          subtitle: l10n.regionCheckEnabledHint,
          value: enabled,
          onChanged: (value) => _update(provider, enabled: value),
        ),
        SettingsSwitchTile(
          title: l10n.regionCheckOnNetworkChange,
          subtitle: l10n.regionCheckOnNetworkChangeHint,
          value: prefs.regionCheckOnNetworkChange,
          onChanged: enabled
              ? (value) => _update(provider, onNetwork: value)
              : (_) {},
        ),
        SettingsTile(
          title: l10n.regionCheckSkipThisRun,
          subtitle: l10n.regionCheckSkipThisRunHint,
          trailing: skipped
              ? Icon(
                  Icons.check_circle_rounded,
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
          onTap: enabled && !skipped ? _skipThisRun : null,
        ),
      ],
    );
  }
}
