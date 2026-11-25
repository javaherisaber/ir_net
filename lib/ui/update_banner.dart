import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/update_checker.dart';

import 'theme.dart';

/// "IRNet 1.7.0 is available": shown while GitHub has a newer release.
/// Clicking it opens the release page; the × hides it until the next one.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    this.compact = false,
    @visibleForTesting this.testInfo,
    @visibleForTesting this.onOpen,
    @visibleForTesting this.onDismiss,
  });

  final bool compact;
  final UpdateInfo? testInfo;
  final VoidCallback? onOpen;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UpdateInfo?>(
      stream: testInfo == null ? bloc.update : Stream.value(testInfo),
      initialData: testInfo,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return _banner(info);
      },
    );
  }

  Widget _banner(UpdateInfo info) {
    const ink = AppColors.onAccent;
    return Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: const BoxDecoration(gradient: AppGradients.brand),
        child: InkWell(
          onTap: onOpen ?? bloc.openUpdate,
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 14 : 12, 11, 2, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: ink.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.system_update_alt, size: 17, color: ink),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Update available', style: AppText.ui(13, FontWeight.w700, ink)),
                      const SizedBox(height: 2),
                      Text('IRNet ${info.version} is out.',
                          style: AppText.ui(11.5, FontWeight.w500, ink.withValues(alpha: 0.85))),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text('Download on GitHub',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.ui(11.5, FontWeight.w700, ink)),
                          ),
                          const Icon(Icons.chevron_right, size: 16, color: ink),
                        ],
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Hide until the next version',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onDismiss ?? bloc.dismissUpdate,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close, size: 15, color: ink.withValues(alpha: 0.7)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
