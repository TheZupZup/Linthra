import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../appearance/selected_logo_mark.dart';
import '../library/selected_folder_controller.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_section.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/plex/plex_settings_section.dart';
import '../settings/source/local_music_controller.dart';
import '../settings/source/provider_summary_cards.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_section.dart';
import 'onboarding_controller.dart';

enum _OnboardingSource { local, jellyfin, subsonic, plex }

/// Linthra's first-run welcome experience.
///
/// Motion is intentionally small and physical: content fades and travels a few
/// pixels rather than flying across the display. System "reduce motion" turns
/// every controller into an immediate transition, so the experience remains
/// comfortable and accessible.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.replay = false});

  /// Settings can replay the tour without clearing the completion flag.
  final bool replay;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _welcomeMotion;
  late final AnimationController _sourceMotion;
  int _step = 0;
  bool _motionStarted = false;
  _OnboardingSource? _busySource;

  @override
  void initState() {
    super.initState();
    _welcomeMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _sourceMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _welcomeMotion.value = 1;
      _sourceMotion.value = 1;
    } else {
      _welcomeMotion.forward();
    }
  }

  @override
  void dispose() {
    _welcomeMotion.dispose();
    _sourceMotion.dispose();
    super.dispose();
  }

  void _showSources() {
    setState(() => _step = 1);
    if (MediaQuery.disableAnimationsOf(context)) {
      _sourceMotion.value = 1;
    } else {
      _sourceMotion.forward(from: 0);
    }
  }

  void _showWelcome() {
    setState(() => _step = 0);
    if (!MediaQuery.disableAnimationsOf(context)) {
      _welcomeMotion.forward(from: .35);
    }
  }

  Future<void> _finish() async {
    await ref.read(onboardingControllerProvider.notifier).complete();
    if (!mounted) return;
    context.go(AppRoutes.library);
  }

  Future<void> _configure(_OnboardingSource source) async {
    if (_busySource != null) return;

    if (source == _OnboardingSource.local) {
      setState(() => _busySource = source);
      try {
        await ref.read(localMusicControllerProvider.notifier).pickFolder();
        final List<String> folders =
            ref.read(selectedFolderControllerProvider).valueOrNull ??
                <String>[];
        if (folders.isNotEmpty) {
          await _finish();
        }
      } finally {
        if (mounted) setState(() => _busySource = null);
      }
      return;
    }

    final Widget settings = switch (source) {
      _OnboardingSource.jellyfin => const JellyfinSettingsSection(),
      _OnboardingSource.subsonic => const SubsonicSettingsSection(),
      _OnboardingSource.plex => const PlexSettingsSection(),
      _OnboardingSource.local => throw StateError('handled above'),
    };

    await showProviderSettingsSheet(context, child: settings);
    if (!mounted) return;

    final bool connected = switch (source) {
      _OnboardingSource.jellyfin =>
        ref.read(jellyfinSettingsControllerProvider).isConnected,
      _OnboardingSource.subsonic =>
        ref.read(subsonicSettingsControllerProvider).isConnected,
      _OnboardingSource.plex =>
        ref.read(plexSettingsControllerProvider).isConnected,
      _OnboardingSource.local => false,
    };
    if (connected) await _finish();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 360),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> animation) {
                final Animation<Offset> slide = Tween<Offset>(
                  begin: const Offset(.025, .015),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: _step == 0
                  ? _WelcomePage(
                      key: const ValueKey<String>('welcome'),
                      motion: _welcomeMotion,
                      onStart: _showSources,
                      onSkip: _finish,
                      replay: widget.replay,
                    )
                  : _SourcePage(
                      key: const ValueKey<String>('sources'),
                      motion: _sourceMotion,
                      busySource: _busySource,
                      onBack: _showWelcome,
                      onSkip: _finish,
                      onSelect: _configure,
                      replay: widget.replay,
                    ),
            ),
          ),
        ),
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({
    super.key,
    required this.motion,
    required this.onStart,
    required this.onSkip,
    required this.replay,
  });

  final AnimationController motion;
  final VoidCallback onStart;
  final VoidCallback onSkip;
  final bool replay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: .66);
    final Animation<double> logoScale =
        Tween<double>(begin: .88, end: 1).animate(
      CurvedAnimation(
        parent: motion,
        curve: const Interval(0, .62, curve: Curves.easeOutBack),
      ),
    );

    // The welcome fills its box so the column can sit optically centred, but
    // it stays scrollable once the copy outgrows a short viewport. The height
    // comes from the box we were actually handed — SafeArea has already taken
    // the system insets off it — rather than from the raw screen size, and it
    // is clamped at zero: subtracting the padding must never be able to hand
    // ConstrainedBox a negative (non-normalized) minimum.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double minHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - (AppSpacing.xl * 2))
                .clamp(0.0, double.infinity)
            : 0.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('welcome-scroll'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xl,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Entrance(
                  controller: motion,
                  begin: 0,
                  end: .55,
                  travel: 14,
                  child: Center(
                    child: ScaleTransition(
                      scale: logoScale,
                      child: const SelectedLinthraLogoMark(size: 96),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                _Entrance(
                  controller: motion,
                  begin: .18,
                  end: .7,
                  child: Text(
                    replay ? 'Welcome back to Linthra' : 'Welcome to Linthra',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.7,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _Entrance(
                  controller: motion,
                  begin: .3,
                  end: .8,
                  child: Text(
                    'Your music. Your servers. Your choice.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(color: muted),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _Entrance(
                  controller: motion,
                  begin: .4,
                  end: .88,
                  child: Text(
                    'Linthra brings local music, Jellyfin, Navidrome / Subsonic and '
                    'Plex into one private, open-source library.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: muted,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                _Entrance(
                  controller: motion,
                  begin: .55,
                  end: 1,
                  child: FilledButton.icon(
                    onPressed: onStart,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label:
                        Text(replay ? 'Explore music sources' : 'Get started'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _Entrance(
                  controller: motion,
                  begin: .64,
                  end: 1,
                  child: TextButton(
                    onPressed: onSkip,
                    child: Text(replay ? 'Done' : 'Skip for now'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SourcePage extends StatelessWidget {
  const _SourcePage({
    super.key,
    required this.motion,
    required this.busySource,
    required this.onBack,
    required this.onSkip,
    required this.onSelect,
    required this.replay,
  });

  final AnimationController motion;
  final _OnboardingSource? busySource;
  final VoidCallback onBack;
  final VoidCallback onSkip;
  final ValueChanged<_OnboardingSource> onSelect;
  final bool replay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: .66);
    final List<
        ({
          _OnboardingSource source,
          IconData icon,
          String title,
          String subtitle,
        })> sources = <({
      _OnboardingSource source,
      IconData icon,
      String title,
      String subtitle,
    })>[
      (
        source: _OnboardingSource.local,
        icon: Icons.folder_special_outlined,
        title: 'Local music',
        subtitle: 'A folder on this phone or an SD card',
      ),
      (
        source: _OnboardingSource.jellyfin,
        icon: Icons.cloud_outlined,
        title: 'Jellyfin',
        subtitle: 'Stream your personal Jellyfin music library',
      ),
      (
        source: _OnboardingSource.subsonic,
        icon: Icons.dns_outlined,
        title: 'Navidrome / Subsonic',
        subtitle: 'Connect to a Subsonic-compatible server',
      ),
      (
        source: _OnboardingSource.plex,
        icon: Icons.video_library_outlined,
        title: 'Plex',
        subtitle: 'Use music from your Plex server',
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: onBack,
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _Entrance(
            controller: motion,
            begin: 0,
            end: .45,
            child: Text(
              'Where is your music?',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -.45,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _Entrance(
            controller: motion,
            begin: .08,
            end: .52,
            child: Text(
              'Pick one source to start. You can add the others later from '
              'Settings → Connections.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: muted,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          for (int index = 0; index < sources.length; index++) ...<Widget>[
            _Entrance(
              controller: motion,
              begin: .13 + (index * .1),
              end: .58 + (index * .1),
              travel: 18,
              child: _SourceCard(
                icon: sources[index].icon,
                title: sources[index].title,
                subtitle: sources[index].subtitle,
                busy: busySource == sources[index].source,
                enabled: busySource == null,
                onTap: () => onSelect(sources[index].source),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          const SizedBox(height: AppSpacing.sm),
          _Entrance(
            controller: motion,
            begin: .58,
            end: 1,
            child: TextButton(
              onPressed: busySource == null ? onSkip : null,
              child: Text(replay ? 'Back to Linthra' : 'Skip for now'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: .62);
    final Duration duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: '${widget.title}. ${widget.subtitle}',
      child: AnimatedScale(
        scale: _pressed ? .985 : 1,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.enabled ? widget.onTap : null,
            onHighlightChanged: (bool value) {
              if (_pressed != value) setState(() => _pressed = value);
            },
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(AppSpacing.md),
              constraints: const BoxConstraints(minHeight: 82),
              child: Row(
                children: <Widget>[
                  AnimatedContainer(
                    duration: duration,
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    child: Icon(widget.icon, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  AnimatedSwitcher(
                    duration: duration,
                    child: widget.busy
                        ? const SizedBox.square(
                            key: ValueKey<String>('busy'),
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.chevron_right_rounded,
                            key: ValueKey<String>('arrow'),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Entrance extends StatelessWidget {
  const _Entrance({
    required this.controller,
    required this.begin,
    required this.end,
    required this.child,
    this.travel = 10,
  });

  final AnimationController controller;
  final double begin;
  final double end;
  final double travel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Animation<double> animation = CurvedAnimation(
      parent: controller,
      curve: Interval(
        begin,
        end,
        curve: Curves.easeOutCubic,
      ),
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? child) {
        return Opacity(
          opacity: animation.value,
          child: Transform.translate(
            offset: Offset(0, travel * (1 - animation.value)),
            child: child,
          ),
        );
      },
    );
  }
}
