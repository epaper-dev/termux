package com.termux.shared.termux.theme;

import org.junit.Assert;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.IOException;

public class TermuxThemeUtilsTest {

    @Rule
    public TemporaryFolder mFolder = new TemporaryFolder();

    @Test
    public void testGetTerminalColorsFileUsesThemeFileIfItExists() throws IOException {
        File colorsFile = mFolder.newFile("colors.properties");
        File themeColorsFile = mFolder.newFile("colors-light.properties");

        Assert.assertEquals(themeColorsFile, TermuxThemeUtils.getTerminalColorsFile(themeColorsFile, colorsFile));
    }

    @Test
    public void testGetTerminalColorsFileUsesColorsFileIfThemeFileDoesNotExist() throws IOException {
        File colorsFile = mFolder.newFile("colors.properties");
        File themeColorsFile = new File(mFolder.getRoot(), "colors-dark.properties");

        Assert.assertEquals(colorsFile, TermuxThemeUtils.getTerminalColorsFile(themeColorsFile, colorsFile));
    }

    @Test
    public void testGetTerminalColorsFileIgnoresThemeDirectory() throws IOException {
        File colorsFile = mFolder.newFile("colors.properties");
        File themeColorsFile = mFolder.newFolder("colors-light.properties");

        Assert.assertEquals(colorsFile, TermuxThemeUtils.getTerminalColorsFile(themeColorsFile, colorsFile));
    }

    @Test
    public void testGetTerminalColorsFileReturnsColorsFileIfNoneExists() {
        File colorsFile = new File(mFolder.getRoot(), "colors.properties");
        File themeColorsFile = new File(mFolder.getRoot(), "colors-light.properties");

        Assert.assertEquals(colorsFile, TermuxThemeUtils.getTerminalColorsFile(themeColorsFile, colorsFile));
    }

}
