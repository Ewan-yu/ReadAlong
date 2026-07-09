import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// 书架页（M0 空壳；M1.3 实现网格卡片/导入/删除，见 design.md §5.4）
class ShelfPage extends StatelessWidget {
  const ShelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ReadAlong 跟读宝'),
        backgroundColor: AppColors.bg,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories, size: 96, color: AppColors.primary.withValues(alpha: 0.4)),
            const SizedBox(height: AppSpacing.pageMargin),
            const Text(
              '让爸爸妈妈用电脑制作绘本资源包，\n然后导入这里吧',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: null, // M1.2 接入导入流程
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('导入绘本', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}
