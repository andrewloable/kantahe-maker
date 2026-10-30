import 'dart:async';

import 'package:kantahe_maker/screens/tap_screen.dart';

/// A TapPlayer that records what the screen asks of it and lets the test move time.
class FakePlayer implements TapPlayer {
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(minutes: 3);
  @override
  bool playing = false;
  final opened = <({String path, Duration start, bool play})>[];
  final seeks = <Duration>[];
  final rates = <double>[];
  bool disposed = false;
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();

  void moveTo(Duration d) {
    position = d;
    _pos.add(d);
  }

  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration> get durationStream => _dur.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Future<void> open(String path, {Duration start = Duration.zero, bool play = false}) async {
    opened.add((path: path, start: start, play: play));
    position = start;
    playing = play;
  }

  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration d) async {
    seeks.add(d);
    position = d;
    _pos.add(d);
  }

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> dispose() async => disposed = true;
}
