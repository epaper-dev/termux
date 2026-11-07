package com.termux.terminal;

/**
 * Keeps the text colours of programs on the right side of the threshold of Android's "High contrast text" (on by
 * default on many E-Ink phones).
 * <p/>
 * Android draws text with R+G+B below the middle ({@link #THRESHOLD}) solid black and other text white with a black
 * outline. On a light background that outlined white text looks hollow, and so does black text with a white outline on
 * a dark one. The built-in colour schemes already keep their 16 colours on the right side, but programs also choose
 * colours of their own: truecolor ({@code ESC [ 38 ; 2 ; R ; G ; B m}) and the 256 colour palette. Claude Code, for
 * example, draws its "thinking" status in a hard-coded grey of 153 to 185, which is hollow on white.
 * <p/>
 * {@link #guard(int, int)} pulls such a colour to the right side of the threshold, keeping its hue as far as possible:
 * on a light background the colour is scaled down, on a dark background it is mixed towards white.
 */
public final class TextContrast {

    /** Text with R+G+B below this is drawn solid black by "High contrast text", other text white with an outline. */
    public static final int THRESHOLD = 384;

    /** On a light background text keeps R+G+B at most this, clearly below {@link #THRESHOLD}. */
    public static final int LIGHT_BACKGROUND_MAX_SUM = 380;

    /** On a dark background text keeps R+G+B at least this, clearly above {@link #THRESHOLD}. */
    public static final int DARK_BACKGROUND_MIN_SUM = 388;

    private static final int WHITE_SUM = 3 * 255;

    private TextContrast() {
    }

    /** R+G+B of a colour (the alpha byte is ignored). */
    public static int channelSum(int color) {
        return ((color >> 16) & 0xFF) + ((color >> 8) & 0xFF) + (color & 0xFF);
    }

    /** Whether text on this background is drawn on the light side, i.e. its R+G+B reaches {@link #THRESHOLD}. */
    public static boolean isLightBackground(int background) {
        return channelSum(background) >= THRESHOLD;
    }

    /**
     * Whether a colour as stored in a {@link TextStyle} is chosen by the program and not by the colour scheme: truecolor
     * ({@code 0xFFrrggbb}) and the palette indices 16 to 255. The 16 scheme colours and the default foreground,
     * background and cursor colours (indices 0 to 15 and 256 and up) belong to the colour scheme, which keeps them
     * right itself, or which the user chose that way in a {@code colors.properties}.
     */
    public static boolean isProgramColor(int styleColor) {
        if ((styleColor & 0xFF000000) == 0xFF000000) return true;
        return styleColor >= 16 && styleColor < 256;
    }

    /**
     * Return {@code foreColor} moved to the right side of {@link #THRESHOLD} for text on {@code backgroundColor}, or
     * unchanged if it is there already.
     * <ul>
     * <li>Light background: R+G+B at most {@link #LIGHT_BACKGROUND_MAX_SUM}, all channels scaled down by the same factor.</li>
     * <li>Dark background: R+G+B at least {@link #DARK_BACKGROUND_MIN_SUM}, all channels mixed towards white by the same
     * share.</li>
     * </ul>
     *
     * @param foreColor       The text colour as {@code 0xAARRGGBB}, after dimming.
     * @param backgroundColor The colour of the background the text is drawn on, as {@code 0xAARRGGBB}.
     * @return The text colour to draw, opaque.
     */
    public static int guard(int foreColor, int backgroundColor) {
        final int red = (foreColor >> 16) & 0xFF;
        final int green = (foreColor >> 8) & 0xFF;
        final int blue = foreColor & 0xFF;
        final int sum = red + green + blue;

        if (isLightBackground(backgroundColor)) {
            if (sum <= LIGHT_BACKGROUND_MAX_SUM) return foreColor;
            return rgb(red * LIGHT_BACKGROUND_MAX_SUM / sum,
                green * LIGHT_BACKGROUND_MAX_SUM / sum,
                blue * LIGHT_BACKGROUND_MAX_SUM / sum);
        }

        if (sum >= DARK_BACKGROUND_MIN_SUM) return foreColor;
        // The share of the way to white that lifts the sum to DARK_BACKGROUND_MIN_SUM is missing / room, always below 1.
        final int missing = DARK_BACKGROUND_MIN_SUM - sum;
        final int room = WHITE_SUM - sum;
        return rgb(red + ceilDiv((255 - red) * missing, room),
            green + ceilDiv((255 - green) * missing, room),
            blue + ceilDiv((255 - blue) * missing, room));
    }

    private static int ceilDiv(int dividend, int divisor) {
        return (dividend + divisor - 1) / divisor;
    }

    private static int rgb(int red, int green, int blue) {
        return 0xFF000000 | (red << 16) | (green << 8) | blue;
    }

}
