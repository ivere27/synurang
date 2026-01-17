import 'package:flutter/material.dart';

// =============================================================================
// Log Panel Widget - Selectable text for copying
// =============================================================================

class LogPanel extends StatelessWidget {
  final List<String> logs;
  final ScrollController scrollController;
  final VoidCallback onClear;

  const LogPanel({
    super.key,
    required this.logs,
    required this.scrollController,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0D1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, color: Colors.white54, size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Output',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all, size: 18),
                  color: Colors.white54,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: 'Clear logs',
                ),
              ],
            ),
          ),
          // Content - Selectable
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      log,
                      style: TextStyle(
                        color: _getLogColor(log),
                        fontSize: 13,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getLogColor(String log) {
    if (log.contains('✅')) return Colors.green.shade300;
    if (log.contains('❌')) return Colors.red.shade300;
    if (log.contains('📥') || log.contains('🔄')) return Colors.blue.shade300;
    if (log.contains('═')) return Colors.yellow.shade300;
    return Colors.white70;
  }
}
