import 'package:flutter/material.dart';

/// 设计 token — 唯一取色来源（docs/design.md §2–4）。
/// 色值/圆角/间距禁止在业务代码中硬编码，一律从这里引用。
abstract final class AppColors {
  // 主色板
  static const primary = Color(0xFF1D8A7E); // 青绿 teal：主按钮/选中/进度条
  static const primaryDark = Color(0xFF166B62); // 主色按下态
  static const primaryContainer = Color(0xFFE3F2EF); // 选中项背景
  static const accent = Color(0xFFF08C1B); // 暖橙：录音/麦克风专用
  static const accentContainer = Color(0xFFFDF0DC);
  static const highlight = Color(0xFFF7E9A8); // 暖黄：bbox 高亮/当前词底色
  static const danger = Color(0xFFD9534F); // 错词标红/删除
  static const success = Color(0xFF3BA55D);

  // 中性色
  static const bg = Color(0xFFF7F5F0); // 阅读端全局暖底（纸感，禁纯白大底）
  static const bgAlt = Color(0xFFFFFFFF); // 卡片、面板
  static const textPrimary = Color(0xFF2B2B2B);
  static const textSecondary = Color(0xFF8A8A8A);
  static const border = Color(0xFFE5E2DB);
}

abstract final class AppRadius {
  static const card = 16.0;
  static const button = 24.0;
  static const thumbnail = 8.0;
  static const subtitleBar = 20.0;
}

abstract final class AppSpacing {
  static const unit = 8.0; // 8dp 基准网格
  static const pageMargin = 24.0;
  static const cardPadding = 16.0;
}

abstract final class AppSizes {
  static const minTouchTarget = 48.0; // 全部可点目标下限
  static const primaryButton = 72.0; // 播放/录音主按钮直径
  static const topBarHeight = 64.0;
  static const thumbnailStripWidth = 76.0;
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      primaryContainer: AppColors.primaryContainer,
      error: AppColors.danger,
      surface: AppColors.bgAlt,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        minimumSize: const Size(AppSizes.minTouchTarget, AppSizes.minTouchTarget),
      ),
    ),
  );
}
