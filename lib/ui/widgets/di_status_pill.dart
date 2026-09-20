import 'package:flutter/material.dart';
import '../../models/automation_models.dart';
import '../theme/app_theme.dart';

class DIStatusPill extends StatelessWidget {
  final DIItem di;

  const DIStatusPill({super.key, required this.di});

  @override
  Widget build(BuildContext context) {
    final isClosed = di.state;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isClosed
            ? AppTheme.accentGreen.withValues(alpha: 0.18)
            : const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isClosed ? AppTheme.accentGreen : AppTheme.cardBorder,
          width: 1.1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isClosed ? AppTheme.accentGreen : AppTheme.textMuted.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'DI ${di.id}${di.isExt ? " (Ek)" : ""}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isClosed ? AppTheme.accentGreen : AppTheme.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isClosed ? 'ON' : 'OFF',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: isClosed ? AppTheme.accentGreen : AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
