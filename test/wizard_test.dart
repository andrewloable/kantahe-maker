import 'package:flutter_test/flutter_test.dart';
import 'package:kantahe_maker/project.dart';
import 'package:kantahe_maker/wizard.dart';

WizardFacts facts({
  bool hasSource = false,
  bool hasInstrumental = false,
  bool separating = false,
  String title = '',
  String artist = '',
  String lyrics = '',
  List<double?> times = const [],
}) => WizardFacts(
  project: SongProject(id: 'x', inputPath: '/x/in.mp3')
    ..title = title
    ..artist = artist
    ..lyrics = lyrics
    ..times = List.of(times),
  hasSource: hasSource,
  hasInstrumental: hasInstrumental,
  separating: separating,
);

WizardFacts finished({String artist = 'A', String lyrics = 'a'}) => facts(
  hasSource: true,
  hasInstrumental: true,
  title: 'T',
  artist: artist,
  lyrics: lyrics,
  times: const [1.0],
);

void main() {
  test('labels_in_order', () {
    expect(WizardStep.values.map(stepLabel).toList(), [
      'Song',
      'Remove vocals',
      'Details',
      'Lyrics',
      'Timing',
      'Export',
    ]);
  });

  test('new_song_opens_on_song', () {
    final f = facts();
    expect(openingStep(f), WizardStep.song);
    expect(canEnter(WizardStep.song, f), isTrue);
    expect(canEnter(WizardStep.vocals, f), isFalse);
  });

  test('source_only_opens_on_vocals', () {
    final f = facts(hasSource: true);
    expect(openingStep(f), WizardStep.vocals);
    expect(canEnter(WizardStep.vocals, f), isTrue);
    expect(canEnter(WizardStep.details, f), isFalse);
  });

  test('separating_lets_the_user_go_on', () {
    final f = facts(hasSource: true, separating: true);
    expect(canEnter(WizardStep.details, f), isTrue);
    expect(openingStep(f), WizardStep.details);
    expect(stepDone(WizardStep.vocals, f), isFalse);
  });

  test('details_need_title_and_artist', () {
    expect(
      stepDone(WizardStep.details, facts(title: 'T', artist: '  ')),
      isFalse,
    );
    expect(
      stepDone(WizardStep.details, facts(title: 'T', artist: ' A\n')),
      isTrue,
    );
  });

  test('lyrics_need_a_line', () {
    expect(stepDone(WizardStep.lyrics, facts(lyrics: '\n  \n')), isFalse);
    expect(stepDone(WizardStep.lyrics, facts(lyrics: 'a')), isTrue);
  });

  test('timing_needs_every_line_tapped_in_order', () {
    bool timed(List<double?> times) =>
        stepDone(WizardStep.timing, facts(lyrics: 'a\nb', times: times));
    expect(timed([1.0, null]), isFalse);
    expect(timed([2.0, 1.0]), isFalse);
    expect(timed([1.0, 2.0]), isTrue);
  });

  test('reopen_finished_song_opens_on_export', () {
    final f = finished();
    expect(openingStep(f), WizardStep.export);
    expect(canEnter(WizardStep.export, f), isTrue);
  });

  test('export_needs_everything_before_it', () {
    final f = finished(artist: '');
    expect(canEnter(WizardStep.export, f), isFalse);
    expect(openingStep(f), WizardStep.details);
  });

  test('an_earlier_gap_wins', () {
    expect(openingStep(finished(lyrics: '')), WizardStep.lyrics);
  });
}
