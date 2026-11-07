package com.termux.shared.termux.theme;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.termux.shared.R;
import com.termux.shared.termux.TermuxConstants;
import com.termux.shared.termux.settings.properties.TermuxPropertyConstants;
import com.termux.shared.termux.settings.properties.TermuxSharedProperties;
import com.termux.shared.theme.NightMode;
import com.termux.shared.theme.ThemeUtils;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Properties;

public class TermuxThemeUtils {

    /** Get the {@link TermuxPropertyConstants#KEY_NIGHT_MODE} value from the properties file on disk
     * and set it to app wide night mode value. */
    public static void setAppNightMode(@NonNull Context context) {
        NightMode.setAppNightMode(TermuxSharedProperties.getNightMode(context));
    }

    /** Set name as app wide night mode value. */
    public static void setAppNightMode(@Nullable String name) {
        NightMode.setAppNightMode(name);
    }

    /**
     * Get the file to load the terminal colors from for the theme in use.
     *
     * If the file for the theme exists, i.e. {@link TermuxConstants#TERMUX_COLOR_PROPERTIES_DARK_FILE} for the dark
     * theme and {@link TermuxConstants#TERMUX_COLOR_PROPERTIES_LIGHT_FILE} for the light theme, then it is used
     * instead of {@link TermuxConstants#TERMUX_COLOR_PROPERTIES_FILE}, which is used otherwise.
     *
     * @param darkTheme If the dark theme is in use, like returned by
     *                  {@link ThemeUtils#shouldEnableDarkTheme(Context, String)}.
     * @return Returns the colors {@link File}. It may not exist.
     */
    @NonNull
    public static File getTerminalColorsFile(boolean darkTheme) {
        return getTerminalColorsFile(
            darkTheme ? TermuxConstants.TERMUX_COLOR_PROPERTIES_DARK_FILE : TermuxConstants.TERMUX_COLOR_PROPERTIES_LIGHT_FILE,
            TermuxConstants.TERMUX_COLOR_PROPERTIES_FILE);
    }

    /**
     * Load the terminal colors for the theme in use, from the file returned by {@link #getTerminalColorsFile(boolean)}.
     *
     * If that file does not exist, the built-in scheme of the theme is used: {@code res/raw/colors_light_default.properties}
     * or {@code res/raw/colors_dark_default.properties} (light colors only, readable on E-Ink).
     *
     * @param context The {@link Context} to read the built-in scheme with.
     * @param darkTheme If the dark theme is in use.
     * @return Returns the colors {@link Properties}, to be used with {@code TerminalColorScheme.updateWith()}.
     * @throws IOException If reading the file failed.
     */
    @NonNull
    public static Properties getTerminalColors(@NonNull Context context, boolean darkTheme) throws IOException {
        final Properties props = new Properties();
        File colorsFile = getTerminalColorsFile(darkTheme);
        if (colorsFile.isFile()) {
            try (InputStream in = new FileInputStream(colorsFile)) {
                props.load(in);
            }
        } else {
            try (InputStream in = context.getResources().openRawResource(
                darkTheme ? R.raw.colors_dark_default : R.raw.colors_light_default)) {
                props.load(in);
            }
        }
        return props;
    }

    /** Return {@code themeColorsFile} if it is a file, otherwise {@code colorsFile}. */
    @NonNull
    static File getTerminalColorsFile(@NonNull File themeColorsFile, @NonNull File colorsFile) {
        return themeColorsFile.isFile() ? themeColorsFile : colorsFile;
    }

}
