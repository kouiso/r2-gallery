import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class VideoSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final String Function(Duration) format;
  final ValueChanged<bool> onScrubbing;
  final ValueChanged<Duration> onSeek;

  const VideoSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.format,
    required this.onScrubbing,
    required this.onSeek,
  });

  @override
  State<VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<VideoSeekBar> {
  int? _pointer;
  double _target = 0;

  double get _max => widget.duration.inMilliseconds.toDouble();

  void _move(double x, double width) {
    setState(
      () => _target = width > 0 ? (x / width).clamp(0.0, 1.0) * _max : 0,
    );
  }

  void _finish({required bool commit}) {
    if (_pointer == null) return;
    setState(() => _pointer = null);
    if (commit) widget.onSeek(Duration(milliseconds: _target.round()));
    widget.onScrubbing(false);
  }

  @override
  Widget build(BuildContext context) {
    final dragging = _pointer != null;
    final max = _max > 0 ? _max : 1.0;
    final value =
        (dragging ? _target : widget.position.inMilliseconds.toDouble()).clamp(
          0.0,
          max,
        );
    final shown = widget.format(Duration(milliseconds: value.round()));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // 少し外した指も、方向が決まる前に確保してページ送りや音量操作へ渡さない。
          return RawGestureDetector(
            key: const ValueKey('seek-region'),
            behavior: HitTestBehavior.opaque,
            gestures: {
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (_) {},
                  ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (_pointer != null || _max <= 0) return;
                _pointer = event.pointer;
                widget.onScrubbing(true);
                _move(event.localPosition.dx, width);
              },
              onPointerMove: (event) {
                if (event.pointer == _pointer) {
                  _move(event.localPosition.dx, width);
                }
              },
              onPointerUp: (event) {
                if (event.pointer != _pointer) return;
                _move(event.localPosition.dx, width);
                _finish(commit: true);
              },
              onPointerCancel: (event) {
                if (event.pointer == _pointer) _finish(commit: false);
              },
              child: SizedBox(
                height: 92,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 16,
                      left: 0,
                      right: 0,
                      height: 56,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: dragging ? 6 : 4,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: dragging ? 12 : 7,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 20,
                          ),
                          overlayColor: Colors.white24,
                        ),
                        child: Slider(
                          key: const ValueKey('seek-slider'),
                          padding: EdgeInsets.zero,
                          value: value,
                          max: max,
                          activeColor: Colors.white,
                          inactiveColor: Colors.white30,
                          semanticFormatterCallback: (x) =>
                              widget.format(Duration(milliseconds: x.round())),
                          onChanged: _max <= 0
                              ? null
                              : (x) => widget.onSeek(
                                  Duration(milliseconds: x.round()),
                                ),
                        ),
                      ),
                    ),
                    if (dragging) ...[
                      Positioned(
                        top: 24,
                        left: value / max * width - 20,
                        child: const IgnorePointer(
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: -8,
                        left: (value / max * width - 32).clamp(
                          0.0,
                          width > 64 ? width - 64 : 0.0,
                        ),
                        child: IgnorePointer(
                          child: Container(
                            key: const ValueKey('seek-preview'),
                            width: 64,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              shown,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    Positioned(
                      top: 72,
                      left: 0,
                      right: 0,
                      height: 20,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            shown,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            widget.format(widget.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
