import 'package:flutter/material.dart';

class ConfidenceBar extends StatelessWidget {
  final String label;
  final double confidence;
  final bool isTop;

  const ConfidenceBar({
    super.key,
    required this.label,
    required this.confidence,
    this.isTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final percentage = (confidence * 100).toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: isTop ? FontWeight.bold : null,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$percentage%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: isTop ? FontWeight.bold : null,
                      color: isTop ? colorScheme.primary : null,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: confidence,
              minHeight: isTop ? 8 : 6,
              backgroundColor: colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                isTop ? colorScheme.primary : colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
