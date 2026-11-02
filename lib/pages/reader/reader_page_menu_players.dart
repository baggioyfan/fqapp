part of '../reader_page.dart';

extension _ReaderPageMenuPlayers on _ReaderPageState {
  Widget _buildReaderMenuPlayers(
    ReaderThemePreset preset,
  ) => ReaderAudioBridge.buildMenuForBook(
    context,
    bookId: widget.bookId,
    builder: (context, currentBook) {
      final match = _videoMatch;
      final video =
          _preferences.showVideoButton && match != null && match.available;
      final reducedMotion =
          preset.isEink ||
          MediaQuery.disableAnimationsOf(context) ||
          MediaQuery.accessibleNavigationOf(context);
      return Stack(
        alignment: Alignment.bottomLeft,
        children: [
          ReaderListenCapsuleHost(monochrome: preset.isEink),
          if (video)
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 87),
              child: Align(
                alignment: Alignment.centerRight,
                child: ReaderVideoButton(
                  menuVisibility: _controlsVisibility,
                  preset: preset,
                  cover: match.covers[match.seriesId] ?? '',
                  loading: _openingVideo,
                  onTap: _loading || _error != null
                      ? null
                      : () => unawaited(_openReaderVideo()),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: currentBook,
            child: ExcludeSemantics(
              excluding: currentBook,
              child: AnimatedSwitcher(
                duration: reducedMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
                child: currentBook
                    ? const SizedBox.shrink()
                    : Padding(
                        key: const ValueKey('reader-listen-entry'),
                        padding: const EdgeInsets.only(right: 16, bottom: 20),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ReaderListenButton(
                            preset: preset,
                            loading: _openingListening,
                            unavailable: _readerAudioUnavailable,
                            // fork 口径：菜单入口先问引擎（听书 / 系统朗读），
                            // 起点固定当前页第一段。不要传 fromPage —— 那会
                            // 跳过引擎菜单直接起播。
                            onTap: _loading || _error != null
                                ? null
                                : () => unawaited(_openListening()),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      );
    },
  );

  bool get _readerAudioUnavailable {
    final tones = _readerTones;
    return !widget.localOnly &&
        tones != null &&
        !tones.hasFixedTone &&
        tones.ttsTones.isEmpty &&
        tones.narratorTones.isEmpty;
  }

  void _loadReaderMenuData() {
    unawaited(_loadVideoMatch());
    unawaited(_loadReaderTones());
  }

  Future<void> _loadReaderTones() async {
    if (widget.localOnly ||
        widget.chapters.isEmpty ||
        _readerTones != null ||
        _readerTonesRequest != null) {
      return;
    }
    final now = DateTime.now();
    if (_readerTonesAttempt != null &&
        now.difference(_readerTonesAttempt!) < const Duration(seconds: 15)) {
      return;
    }
    _readerTonesAttempt = now;
    final request = _readerTonesRequest = BackendRequest();
    try {
      final tones = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.bookTones(widget.bookId),
      );
      if (mounted && !request.isCancelled) {
        _setState(() => _readerTones = tones);
      }
    } catch (_) {
      // Unknown availability is retryable, not a copyright denial.
    } finally {
      if (identical(_readerTonesRequest, request)) _readerTonesRequest = null;
    }
  }
}
