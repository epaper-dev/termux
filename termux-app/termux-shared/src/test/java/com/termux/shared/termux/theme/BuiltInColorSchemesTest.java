package com.termux.shared.termux.theme;

import com.termux.terminal.TerminalColorScheme;
import com.termux.terminal.TextStyle;

import org.junit.Assert;
import org.junit.Test;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Properties;

/**
 * Checks the built-in light and dark schemes the way {@code TermuxThemeUtils.getTerminalColors()} loads them, and that
 * no text color is near the middle: Android's "High contrast text" draws text with R+G+B below 384 black with a white
 * outline and other text white with a black outline, so a color on the wrong side looks hollow.
 */
public class BuiltInColorSchemesTest {

    /** The module directory is the working directory of the unit tests. */
    private static final File LIGHT_DEFAULT = new File("src/main/res/raw/colors_light_default.properties");
    private static final File DARK_DEFAULT = new File("src/main/res/raw/colors_dark_default.properties");

    private static Properties load(File file) throws IOException {
        Properties props = new Properties();
        try (InputStream in = new FileInputStream(file)) {
            props.load(in);
        }
        return props;
    }

    private static int channelSum(int color) {
        return ((color >> 16) & 0xFF) + ((color >> 8) & 0xFF) + (color & 0xFF);
    }

    private static TerminalColorScheme scheme(File file) throws IOException {
        TerminalColorScheme scheme = new TerminalColorScheme();
        // throws IllegalArgumentException for an unknown key or an invalid color
        scheme.updateWith(load(file));
        return scheme;
    }

    @Test
    public void testBuiltInLightScheme() throws IOException {
        TerminalColorScheme scheme = scheme(LIGHT_DEFAULT);
        Assert.assertEquals(0xFFFFFFFF, scheme.mDefaultColors[TextStyle.COLOR_INDEX_BACKGROUND]);
        Assert.assertEquals(0xFF000000, scheme.mDefaultColors[TextStyle.COLOR_INDEX_FOREGROUND]);
        Assert.assertEquals(0xFF000000, scheme.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR]);
        // color15 (white) is the background color of the palette
        for (int i = 0; i < 15; i++)
            Assert.assertTrue("color" + i + " dark enough", channelSum(scheme.mDefaultColors[i]) < 384);
    }

    @Test
    public void testBuiltInDarkScheme() throws IOException {
        TerminalColorScheme scheme = scheme(DARK_DEFAULT);
        Assert.assertEquals(0xFF000000, scheme.mDefaultColors[TextStyle.COLOR_INDEX_BACKGROUND]);
        Assert.assertEquals(0xFFFFFFFF, scheme.mDefaultColors[TextStyle.COLOR_INDEX_FOREGROUND]);
        Assert.assertEquals(0xFFFFFFFF, scheme.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR]);
        // color0 (black) is the background color of the palette; dimmed text has 2/3 of the color
        for (int i = 1; i < 16; i++)
            Assert.assertTrue("color" + i + " light enough, also dimmed", channelSum(scheme.mDefaultColors[i]) * 2 / 3 >= 384);
    }

    @Test
    public void testBuiltInSchemesDefineAllSixteenColors() throws IOException {
        for (File file : new File[]{LIGHT_DEFAULT, DARK_DEFAULT}) {
            Properties props = load(file);
            for (int i = 0; i < 16; i++)
                Assert.assertNotNull(file.getName() + ": color" + i, props.getProperty("color" + i));
        }
    }

}
