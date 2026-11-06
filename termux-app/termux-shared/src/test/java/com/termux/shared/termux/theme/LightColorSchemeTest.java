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

/** Checks the built-in light scheme the way {@code TermuxThemeUtils.getTerminalColors()} loads it. */
public class LightColorSchemeTest {

    /** The module directory is the working directory of the unit tests. */
    private static final File LIGHT_DEFAULT = new File("src/main/res/raw/colors_light_default.properties");

    private static Properties load() throws IOException {
        Properties props = new Properties();
        try (InputStream in = new FileInputStream(LIGHT_DEFAULT)) {
            props.load(in);
        }
        return props;
    }

    @Test
    public void testBuiltInLightSchemeIsAcceptedByTheColorScheme() throws IOException {
        TerminalColorScheme scheme = new TerminalColorScheme();
        // throws IllegalArgumentException for an unknown key or an invalid color
        scheme.updateWith(load());

        Assert.assertEquals(0xFFFFFFFF, scheme.mDefaultColors[TextStyle.COLOR_INDEX_BACKGROUND]);
        Assert.assertEquals(0xFF000000, scheme.mDefaultColors[TextStyle.COLOR_INDEX_FOREGROUND]);
        Assert.assertEquals(0xFF000000, scheme.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR]);
    }

    @Test
    public void testBuiltInLightSchemeDefinesAllSixteenColors() throws IOException {
        Properties props = load();
        for (int i = 0; i < 16; i++)
            Assert.assertNotNull("color" + i, props.getProperty("color" + i));
    }

}
