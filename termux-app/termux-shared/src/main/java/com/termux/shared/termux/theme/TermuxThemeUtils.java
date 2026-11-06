package com.termux.shared.termux.theme;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.termux.shared.termux.TermuxConstants;
import com.termux.shared.termux.settings.properties.TermuxPropertyConstants;
import com.termux.shared.termux.settings.properties.TermuxSharedProperties;
import com.termux.shared.theme.NightMode;
import com.termux.shared.theme.ThemeUtils;

import java.io.File;

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

    /** Return {@code themeColorsFile} if it is a file, otherwise {@code colorsFile}. */
    @NonNull
    static File getTerminalColorsFile(@NonNull File themeColorsFile, @NonNull File colorsFile) {
        return themeColorsFile.isFile() ? themeColorsFile : colorsFile;
    }

}
