// The song wizard's steps: which are done, which the user may open, where a song opens.
// Pure Dart: no Flutter imports.

import 'export.dart';
import 'project.dart';

enum WizardStep { song, vocals, details, lyrics, timing, export }

String stepLabel(WizardStep step) => switch (step) {
  WizardStep.song => 'Song',
  WizardStep.vocals => 'Remove vocals',
  WizardStep.details => 'Details',
  WizardStep.lyrics => 'Lyrics',
  WizardStep.timing => 'Timing',
  WizardStep.export => 'Export',
};

/// What the wizard needs to know about a song besides its project.
class WizardFacts {
  const WizardFacts({
    required this.project,
    required this.hasSource,
    required this.hasInstrumental,
    required this.separating,
  });

  final SongProject project;

  /// The song's audio has been extracted (source.mp3 exists).
  final bool hasSource;

  /// Vocal removal has finished (instrumental.mp3 exists).
  final bool hasInstrumental;

  /// Vocal removal is running.
  final bool separating;
}

/// Whether [step] needs nothing more. Export is never done: an export leaves no record.
bool stepDone(WizardStep step, WizardFacts f) {
  final p = f.project;
  return switch (step) {
    WizardStep.song => f.hasSource,
    WizardStep.vocals => f.hasInstrumental,
    WizardStep.details =>
      oneLine(p.title).isNotEmpty && oneLine(p.artist).isNotEmpty,
    WizardStep.lyrics => p.lyricLines().isNotEmpty,
    WizardStep.timing =>
      p.lyricLines().isNotEmpty && timingBlockers(p).isEmpty,
    WizardStep.export => false,
  };
}

/// A step the user can go on past without finishing it: vocal removal runs behind.
bool _passable(WizardStep step, WizardFacts f) =>
    stepDone(step, f) || (step == WizardStep.vocals && f.separating);

/// Whether the user may open [step]: every step before it is done (or running behind).
bool canEnter(WizardStep step, WizardFacts f) =>
    WizardStep.values.take(step.index).every((e) => _passable(e, f));

/// The step a song opens on: the first one that still needs the user.
WizardStep openingStep(WizardFacts f) =>
    WizardStep.values.firstWhere((s) => !_passable(s, f));
