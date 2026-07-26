/**
 * Material 3–inspired tokens matching Android KDE Connect (DynamicColors light defaults).
 * KDE brand accent from launcher_background: #3daee9
 */

export class UiTheme {
  // Brand
  static readonly kdeBlue: string = '#3DAEE9';
  static readonly primary: string = '#1A73E8';
  static readonly onPrimary: string = '#FFFFFF';
  static readonly primaryContainer: string = '#D2E3FC';
  static readonly onPrimaryContainer: string = '#041E49';

  // Surfaces (M3 light)
  static readonly pageBg: string = '#FDFBFF';
  static readonly surface: string = '#FDFBFF';
  static readonly surfaceVariant: string = '#E7E0EC';
  static readonly cardBg: string = '#FFFFFF';
  static readonly cardElevated: string = '#FFFFFF';
  static readonly sidebarBg: string = '#F7F2FA';
  static readonly divider: string = '#CAC4D0';
  static readonly scrim: string = '#99000000';
  static readonly ripple: string = '#1F000000';

  // Text
  static readonly onSurface: string = '#1C1B1F';
  static readonly onSurfaceVariant: string = '#49454F';
  static readonly outline: string = '#79747E';
  static readonly textMuted: string = '#79747E';

  // Semantic (Android summary red #CC2222)
  static readonly danger: string = '#CC2222';
  static readonly error: string = '#B3261E';
  static readonly success: string = '#1B8A4A';
  static readonly findPhone: string = '#C62828';
  static readonly findPhoneDark: string = '#B71C1C';

  // Icon
  static readonly iconTint: string = '#49454F';
  static readonly iconOnSurface: string = '#1C1B1F';

  // Elevation / radius (Material 3 card)
  static readonly radiusCard: number = 12;
  static readonly radiusButton: number = 24;
  static readonly radiusChip: number = 8;
  static readonly radiusFull: number = 999;
  static readonly cardMargin: number = 4;
  static readonly pageHPad: number = 12;
  static readonly sectionPadTop: number = 16;
  static readonly sectionPadH: number = 16;
  static readonly listItemMinH: number = 56;
  static readonly toolbarH: number = 56;
  static readonly iconSize: number = 24;
  static readonly deviceIconSize: number = 32;
  static readonly pluginIconSize: number = 28;

  // Motion (Material standard)
  static readonly durationShort: number = 150;
  static readonly durationMedium: number = 250;
  static readonly durationLong: number = 350;
  static readonly durationDrawer: number = 280;
  static readonly durationRefresh: number = 1500;

  // Typography sizes (sp ≈ vp)
  static readonly titleLg: number = 22;
  static readonly titleMd: number = 16;
  static readonly bodyLg: number = 18;
  static readonly bodyMd: number = 14;
  static readonly bodySm: number = 12;
  static readonly labelMd: number = 14;
}
