import 'package:flutter/material.dart';

import 'linkified_text.dart';

import 'glass_container.dart';

/// Formats a backend `due_date` ("YYYY-MM-DD") the way the student screens show
/// it. Shared so the Tasks tab and the Assignments screen cannot drift apart.
String formatAssignmentDueDate(String rawDate) {
  try {
    final date = DateTime.parse(rawDate);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  } catch (_) {
    return rawDate;
  }
}

/// One assignment, rendered exactly as the Tasks tab has always rendered it.
///
/// Extracted from `tasks.dart` so the dedicated Assignments screen reuses the
/// same card instead of a look-alike. The assignment's [description] is an
/// optional extra: the backend returns it, the Tasks tab does not pass it, so
/// Tasks is pixel-identical to before.
class AssignmentCard extends StatelessWidget {
  const AssignmentCard({
    super.key,
    required this.title,
    required this.subject,
    required this.dueDate,
    this.batch,
    this.description,
    this.hasAttachment = false,
    this.attachmentName,
    this.isVideo = false,
    this.fileCount = 1,
    this.onOpen,
  });

  final String title;
  final String subject;

  /// Already formatted by [formatAssignmentDueDate].
  final String dueDate;
  final String? batch;
  final String? description;
  final bool hasAttachment;
  final String? attachmentName;

  /// True when the attachment is a video, so the card offers the right action
  /// instead of telling a student to "READ" a recording. Defaults to false:
  /// every caller that predates video uploads keeps its exact wording.
  final bool isVideo;

  /// How many files the assignment carries. The card opens the first one; the
  /// label says how many there are so a multi-file post is not mistaken for a
  /// single attachment.
  final int fileCount;

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      // Tapping the card opens the reader; a card without an attachment stays
      // inert rather than pretending to be tappable.
      onTap: hasAttachment ? onOpen : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassContainer(
                width: 48,
                height: 48,
                borderRadius: 12,
                padding: EdgeInsets.zero,
                blurStrength: 15,
                opacity: 0.7,
                borderOpacity: 0.4,
                child: Icon(
                  isVideo
                      ? Icons.play_circle_fill_rounded
                      : Icons.assignment_rounded,
                  size: 24,
                  color: GlassColors.primaryBlue,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: GlassColors.headingOf(context),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (batch != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: GlassContainer(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              borderRadius: 8,
                              blurStrength: 10,
                              opacity: 0.6,
                              borderOpacity: 0.3,
                              child: Text(
                                batch!,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: GlassColors.primaryBlue,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.book_rounded,
                          size: 13,
                          color: GlassColors.secondaryTextOf(context),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            subject,
                            style: TextStyle(
                              fontSize: 13,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Icon(
                          Icons.calendar_today_rounded,
                          size: 13,
                          color: GlassColors.secondaryTextOf(context),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Due: $dueDate',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: GlassColors.secondaryTextOf(context),
                size: 22,
              ),
            ],
          ),
          if (description != null && description!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            LinkifiedText(
              description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: GlassColors.secondaryTextOf(context),
              ),
              linkStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          if (hasAttachment) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  isVideo
                      ? Icons.play_circle_outline_rounded
                      : Icons.picture_as_pdf_rounded,
                  size: 16,
                  color: GlassColors.primaryBlue,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    fileCount > 1
                        ? '$fileCount files'
                        : attachmentName ?? 'Attached PDF',
                    style: TextStyle(
                      fontSize: 12,
                      color: GlassColors.secondaryTextOf(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: GlassButton(
                    onPressed: onOpen,
                    color: GlassColors.primaryBlue,
                    height: 36,
                    borderRadius: 10,
                    child: Text(
                      isVideo ? 'PLAY VIDEO' : 'READ PDF',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
