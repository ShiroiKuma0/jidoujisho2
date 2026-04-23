/// Settings that are persisted for the secondary subtitle appearance.
class SecondarySubtitleOptions {
  /// Initialise this object.
  SecondarySubtitleOptions({
    required this.fontSize,
    required this.fontName,
    required this.fontColor,
    required this.fontWeight,
    required this.subtitleOutlineWidth,
    required this.subtitleOutlineColor,
    required this.subtitleBackgroundBlurRadius,
    required this.subtitleBackgroundOpacity,
    required this.verticalOffset,
  });

  /// Subtitle font size.
  double fontSize;

  /// Name of the font preferred for the subtitle.
  String fontName;

  /// Font color preferred for the subtitle.
  int fontColor;

  /// Font weight preferred for the subtitle.
  String fontWeight;

  /// Subtitle outline width.
  double subtitleOutlineWidth;

  /// Subtitle outline color.
  int subtitleOutlineColor;

  /// Subtitle background blur radius.
  double subtitleBackgroundBlurRadius;

  /// Subtitle background opacity.
  double subtitleBackgroundOpacity;

  /// Vertical offset for subtitle position in pixels.
  double verticalOffset;
}
