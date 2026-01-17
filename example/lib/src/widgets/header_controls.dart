import 'package:flutter/material.dart';

// =============================================================================
// Header Controls Widget - Token input and server toggles
// =============================================================================

class HeaderControls extends StatelessWidget {
  final String token;
  final ValueChanged<String> onTokenChanged;
  final VoidCallback onGenerateToken;

  final bool goUdsRunning;
  final bool goTcpRunning;
  final bool flutterUdsRunning;
  final bool flutterTcpRunning;

  final VoidCallback onToggleGoUds;
  final VoidCallback onToggleGoTcp;
  final VoidCallback onToggleFlutterUds;
  final VoidCallback onToggleFlutterTcp;

  final int passedTests;
  final int failedTests;
  final VoidCallback onRunAll;
  final VoidCallback onRunAllMixed;
  final VoidCallback onReset;
  final VoidCallback onFileTests;
  final bool isRunningAll;

  const HeaderControls({
    super.key,
    required this.token,
    required this.onTokenChanged,
    required this.onGenerateToken,
    required this.goUdsRunning,
    required this.goTcpRunning,
    required this.flutterUdsRunning,
    required this.flutterTcpRunning,
    required this.onToggleGoUds,
    required this.onToggleGoTcp,
    required this.onToggleFlutterUds,
    required this.onToggleFlutterTcp,
    required this.passedTests,
    required this.failedTests,
    required this.onRunAll,
    required this.onRunAllMixed,
    required this.onReset,
    required this.onFileTests,
    required this.isRunningAll,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Title and Token
          Row(
            children: [
              const Text(
                'Synurang Test Suite',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              // Token input
              _buildTokenInput(),
            ],
          ),
          const SizedBox(height: 12),
          // Row 2: Server toggles and actions
          Row(
            children: [
              // Go servers
              _buildServerToggle('Go UDS', goUdsRunning, onToggleGoUds),
              const SizedBox(width: 10),
              _buildServerToggle('Go TCP', goTcpRunning, onToggleGoTcp),
              const SizedBox(width: 20),
              // Flutter servers
              _buildServerToggle(
                'Flutter UDS',
                flutterUdsRunning,
                onToggleFlutterUds,
              ),
              const SizedBox(width: 10),
              _buildServerToggle(
                'Flutter TCP',
                flutterTcpRunning,
                onToggleFlutterTcp,
              ),
              const Spacer(),
              // Stats
              _buildStatBadge('✅', passedTests, Colors.green),
              const SizedBox(width: 10),
              _buildStatBadge('❌', failedTests, Colors.red),
              const SizedBox(width: 16),
              // Actions
              FilledButton.icon(
                onPressed: !isRunningAll ? onRunAll : null,
                icon: isRunningAll
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow, size: 20),
                label: const Text('Run', style: TextStyle(fontSize: 14)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: !isRunningAll ? onRunAllMixed : null,
                icon: const Icon(Icons.all_inclusive, size: 20),
                label: const Text('ALL', style: TextStyle(fontSize: 14)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Reset', style: TextStyle(fontSize: 14)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onFileTests,
                icon: const Icon(Icons.file_upload, size: 20),
                label: const Text('Files', style: TextStyle(fontSize: 14)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTokenInput() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Token: ',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        Container(
          width: 200,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: TextField(
            controller: TextEditingController(text: token),
            onChanged: onTokenChanged,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Token',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: onGenerateToken,
          icon: const Icon(Icons.casino, size: 20),
          color: Colors.white54,
          tooltip: 'Generate random token',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }

  Widget _buildServerToggle(
    String label,
    bool isRunning,
    VoidCallback onToggle,
  ) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isRunning
              ? Colors.green.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isRunning
                ? Colors.green.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isRunning ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isRunning ? Colors.white : Colors.white70,
                fontSize: 13,
                fontWeight: isRunning ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatBadge(String emoji, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 4),
        Text(
          '$count',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ],
    );
  }
}
