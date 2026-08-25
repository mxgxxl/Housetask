import '../../data/models/task.dart';

/// How the timeline groups and orders tasks, in one place.
///
/// Extracted from TaskCubit (TD-064) rather than copied into TimelineCubit:
/// the two render the same surface during the transition, and "which day does
/// this task belong to" and "in what order" are exactly the kind of semantics
/// that drift when duplicated. This repo already carries one deliberate
/// duplicate with a KEEP BOTH COPIES IN SYNC warning on it (TaskCubit's and
/// ShoppingCubit's optimistic overlays); one is enough.
class TimelineGroups {
  final Map<DateTime, List<Task>> days;
  final List<Task> undated;
  const TimelineGroups(this.days, this.undated);
}

/// Midnight of [d]'s LOCAL day — the day boundary the user actually sees,
/// independent of the household timezone work still pending in TD-013.
DateTime startOfLocalDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime endOfLocalDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// Pending first, then by due date ascending (nulls last).
List<Task> sortTasksForDisplay(List<Task> tasks) {
  final copy = List<Task>.from(tasks);
  copy.sort((a, b) {
    if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return copy;
}

/// Split [tasks] into per-local-day buckets plus the undated ones.
///
/// Takes an iterable of already-deduplicated tasks: callers that hold state
/// keyed by id pass `byId.values`, which is what makes a duplicate row
/// impossible rather than merely unlikely.
TimelineGroups groupTasksByLocalDay(Iterable<Task> tasks) {
  final days = <DateTime, List<Task>>{};
  final undated = <Task>[];
  for (final task in tasks) {
    final due = task.dueDate;
    if (due == null) {
      undated.add(task);
      continue;
    }
    final key = startOfLocalDay(due.toLocal());
    (days[key] ??= []).add(task);
  }
  for (final key in days.keys) {
    days[key] = sortTasksForDisplay(days[key]!);
  }
  return TimelineGroups(days, undated);
}
