import 'package:flutter/material.dart';

// =============================================================================
// Test Card Widget
// =============================================================================

enum TestStatus { idle, running, passed, failed }

class TestResult {
  final TestStatus status;
  final String? message;
  final int? durationMs;
  final List<String>? streamMessages;

  TestResult({
    this.status = TestStatus.idle,
    this.message,
    this.durationMs,
    this.streamMessages,
  });
}

class TestCard extends StatelessWidget {
  final String id;
  final String title;
  final String? transport;
  final TestResult result;
  final VoidCallback onRun;

  const TestCard({
    super.key,
    required this.id,
    required this.title,
    this.transport,
    required this.result,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: result.status != TestStatus.running ? onRun : null,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _getBackgroundColor(),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _getBorderColor()),
        ),
        child: Row(
          children: [
            _buildStatusIcon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          fontSize: 15,
                        ),
                      ),
                      if (transport != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            transport!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (result.message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        result.message!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (result.durationMs != null)
              Text(
                '${result.durationMs}ms',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (result.status) {
      case TestStatus.idle:
        return const Icon(
          Icons.play_circle_outline,
          color: Colors.white38,
          size: 24,
        );
      case TestStatus.running:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
        );
      case TestStatus.passed:
        return Icon(Icons.check_circle, color: Colors.green.shade400, size: 24);
      case TestStatus.failed:
        return Icon(Icons.error, color: Colors.red.shade400, size: 24);
    }
  }

  Color _getBackgroundColor() {
    switch (result.status) {
      case TestStatus.passed:
        return Colors.green.withValues(alpha: 0.1);
      case TestStatus.failed:
        return Colors.red.withValues(alpha: 0.1);
      default:
        return Colors.white.withValues(alpha: 0.03);
    }
  }

  Color _getBorderColor() {
    switch (result.status) {
      case TestStatus.passed:
        return Colors.green.withValues(alpha: 0.3);
      case TestStatus.failed:
        return Colors.red.withValues(alpha: 0.3);
      default:
        return Colors.white.withValues(alpha: 0.1);
    }
  }
}
