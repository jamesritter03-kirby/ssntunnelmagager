using System;
using System.Collections.Generic;

namespace RemoteStuff.Views.Controls;

/// <summary>
/// Central catalogue of monochrome line-icon geometries (Lucide, ISC-licensed) used
/// throughout the app so the cross-platform UI matches the macOS app's SF-Symbol look.
/// Each value is SVG path data authored on a 24×24 canvas and rendered stroked by
/// <see cref="LineIcon"/>. <see cref="Resolve"/> also maps common SF-Symbol names
/// (imported from the macOS app's profiles) onto the closest icon.
/// </summary>
public static class AppIcons
{
    private static readonly Dictionary<string, string> Paths = new(StringComparer.OrdinalIgnoreCase)
    {
        ["a-arrow-down"] = "M14 12 l 4 4 4-4 M18 16V7 M2 16 l 4.039-9.69a.5.5 0 0 1 .923 0L11 16 M3.304 13h6.392",
        ["a-arrow-up"] = "M14 11 l 4-4 4 4 M18 16V7 M2 16 l 4.039-9.69a.5.5 0 0 1 .923 0L11 16 M3.304 13h6.392",
        ["arrow-down-to-line"] = "M12 17V3 M6 11 l 6 6 6-6 M19 21H5",
        ["arrow-up-down"] = "M21 16 l-4 4-4-4 M17 20V4 M3 8 l 4-4 4 4 M7 4v16",
        ["bookmark"] = "M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z",
        ["calculator"] = "M6 2h12a2 2 0 0 1 2 2v16a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2v-16a2 2 0 0 1 2 -2z M8 6L16 6 M16 14L16 18 M16 10h.01 M12 10h.01 M8 10h.01 M12 14h.01 M8 14h.01 M12 18h.01 M8 18h.01",
        ["check"] = "M20 6 9 17l-5-5",
        ["chevron-left"] = "M15 18 l-6-6 6-6",
        ["chevron-right"] = "M9 18 l 6-6-6-6",
        ["chevron-up"] = "M18 15 l-6-6-6 6",
        ["chevron-down"] = "M6 9 l 6 6 6-6",
        ["chevrons-down"] = "M7 6 l 5 5 5-5 M7 13 l 5 5 5-5",
        ["chevrons-up"] = "M17 11 l-5-5-5 5 M17 18 l-5-5-5 5",
        ["maximize-2"] = "M15 3h6v6 M9 21H3v-6 M21 3 l-7 7 M3 21 l7-7",
        ["minimize-2"] = "M4 14h6v6 M20 10h-6V4 M14 10 l7-7 M3 21 l7-7",
        ["clipboard"] = "M9 2h6a1 1 0 0 1 1 1v2a1 1 0 0 1 -1 1h-6a1 1 0 0 1 -1 -1v-2a1 1 0 0 1 1 -1z M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2",
        ["moon"] = "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9",
        ["command"] = "M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3",
        ["plus"] = "M5 12h14 M12 5v14",
        ["cloud"] = "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z",
        ["copy"] = "M10 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2v-10a2 2 0 0 1 2 -2z M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2",
        ["corner-up-left"] = "M20 20v-7a4 4 0 0 0-4-4H4 M9 14 4 9l5-5",
        ["cpu"] = "M12 20v2 M12 2v2 M17 20v2 M17 2v2 M2 12h2 M2 17h2 M2 7h2 M20 12h2 M20 17h2 M20 7h2 M7 20v2 M7 2v2 M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2v-12a2 2 0 0 1 2 -2z M9 8h6a1 1 0 0 1 1 1v6a1 1 0 0 1 -1 1h-6a1 1 0 0 1 -1 -1v-6a1 1 0 0 1 1 -1z",
        ["database"] = "M3 5a9 3 0 1 0 18 0a9 3 0 1 0 -18 0 M3 5V19A9 3 0 0 0 21 19V5 M3 12A9 3 0 0 0 21 12",
        ["download"] = "M12 15V3 M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10 l 5 5 5-5",
        ["ellipsis-vertical"] = "M11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0 M11 5a1 1 0 1 0 2 0a1 1 0 1 0 -2 0 M11 19a1 1 0 1 0 2 0a1 1 0 1 0 -2 0",
        ["external-link"] = "M15 3h6v6 M10 14 21 3 M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6",
        ["eye"] = "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0",
        ["file"] = "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z M14 2v5a1 1 0 0 0 1 1h5",
        ["file-plus"] = "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z M14 2v5a1 1 0 0 0 1 1h5 M9 15h6 M12 18v-6",
        ["file-text"] = "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z M14 2v5a1 1 0 0 0 1 1h5 M10 9H8 M16 13H8 M16 17H8",
        ["folder"] = "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z",
        ["folder-open"] = "M6 14 l 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2",
        ["folder-plus"] = "M12 10v6 M9 13h6 M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z",
        ["folders"] = "M20 5a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h2.5a1.5 1.5 0 0 1 1.2.6l.6.8a1.5 1.5 0 0 0 1.2.6z M3 8.268a2 2 0 0 0-1 1.738V19a2 2 0 0 0 2 2h11a2 2 0 0 0 1.732-1",
        ["git-compare"] = "M15 18a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M3 6a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M13 6h3a2 2 0 0 1 2 2v7 M11 18H8a2 2 0 0 1-2-2V9",
        ["globe"] = "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20 M2 12h20",
        ["hard-drive"] = "M10 16h.01 M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M21.946 12.013H2.054 M6 16h.01",
        ["highlighter"] = "M9 11 l-6 6v3h9l3-3 M22 12 l-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4",
        ["history"] = "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8 M3 3v5h5 M12 7v5l4 2",
        ["indent-increase"] = "M3 8 l 4 4-4 4 M21 12H11 M21 6H11 M21 18H11",
        ["fold-vertical"] = "M12 22v-6 M12 8V2 M4 12H2 M10 12H8 M16 12h-2 M22 12h-2 M15 19 l-3-3-3 3 M15 5 l-3 3-3-3",
        ["house"] = "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8 M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
        ["key-round"] = "M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z M16 7.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0",
        ["laptop"] = "M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z M20.054 15.987H3.946",
        ["link"] = "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71",
        ["list-ordered"] = "M11 5h10 M11 12h10 M11 19h10 M4 4h1v5 M4 9h2 M6.5 20H3.4c0-1 2.6-1.925 2.6-3.5a1.5 1.5 0 0 0-2.6-1.02",
        ["lock"] = "M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-7a2 2 0 0 1 2 -2z M7 11V7a5 5 0 0 1 10 0v4",
        ["monitor"] = "M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-16a2 2 0 0 1 -2 -2v-10a2 2 0 0 1 2 -2z M8 21L16 21 M12 17L12 21",
        ["network"] = "M17 16h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1v-4a1 1 0 0 1 1 -1z M3 16h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1v-4a1 1 0 0 1 1 -1z M10 2h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1v-4a1 1 0 0 1 1 -1z M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3 M12 12V8",
        ["package"] = "M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z M12 22V12 M3.29 7L12 12L20.71 7 M7.5 4.27 l 9 5.15",
        ["palette"] = "M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z M13 6.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0 M17 10.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0 M6 12.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0 M8 7.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0",
        ["panel-left"] = "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z M9 3v18",
        ["pilcrow"] = "M13 4v16 M17 4v16 M19 4H9.5a4.5 4.5 0 0 0 0 9H13",
        ["pin"] = "M12 17v5 M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z",
        ["play"] = "M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z",
        ["plug"] = "M12 22v-5 M15 8V2 M17 8a1 1 0 0 1 1 1v4a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z M9 8V2",
        ["radio"] = "M16.247 7.761a6 6 0 0 1 0 8.478 M19.075 4.933a10 10 0 0 1 0 14.134 M4.925 19.067a10 10 0 0 1 0-14.134 M7.753 16.239a6 6 0 0 1 0-8.478 M10 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0",
        ["refresh-cw"] = "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8 M21 3v5h-5 M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16 M8 16H3v5",
        ["router"] = "M4 14h16a2 2 0 0 1 2 2v4a2 2 0 0 1 -2 2h-16a2 2 0 0 1 -2 -2v-4a2 2 0 0 1 2 -2z M6.01 18H6 M10.01 18H10 M15 10v4 M17.84 7.17a4 4 0 0 0-5.66 0 M20.66 4.34a8 8 0 0 0-11.31 0",
        ["ruler"] = "M21.3 15.3a2.4 2.4 0 0 1 0 3.4l-2.6 2.6a2.4 2.4 0 0 1-3.4 0L2.7 8.7a2.41 2.41 0 0 1 0-3.4l2.6-2.6a2.41 2.41 0 0 1 3.4 0Z M14.5 12.5 l 2-2 M11.5 9.5 l 2-2 M8.5 6.5 l 2-2 M17.5 15.5 l 2-2",
        ["save"] = "M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7 M7 3v4a1 1 0 0 0 1 1h7",
        ["save-all"] = "M10 2v3a1 1 0 0 0 1 1h5 M18 18v-6a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6 M18 22H4a2 2 0 0 1-2-2V6 M8 18a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9.172a2 2 0 0 1 1.414.586l2.828 2.828A2 2 0 0 1 22 6.828V16a2 2 0 0 1-2.01 2z",
        ["search"] = "M21 21 l-4.34-4.34 M3 11a8 8 0 1 0 16 0a8 8 0 1 0 -16 0",
        ["server"] = "M4 2h16a2 2 0 0 1 2 2v4a2 2 0 0 1 -2 2h-16a2 2 0 0 1 -2 -2v-4a2 2 0 0 1 2 -2z M4 14h16a2 2 0 0 1 2 2v4a2 2 0 0 1 -2 2h-16a2 2 0 0 1 -2 -2v-4a2 2 0 0 1 2 -2z M6 6L6.01 6 M6 18L6.01 18",
        ["settings"] = "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0",
        ["square-code"] = "M10 9 l-3 3 3 3 M14 15 l 3-3-3-3 M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z",
        ["square-pen"] = "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7 M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z",
        ["square-terminal"] = "M7 11 l 2-2-2-2 M11 13h4 M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z",
        ["star"] = "M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z",
        ["table"] = "M12 3v18 M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z M3 9h18 M3 15h18",
        ["text-cursor-input"] = "M12 20h-1a2 2 0 0 1-2-2 2 2 0 0 1-2 2H6 M13 8h7a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-7 M5 16H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h1 M6 4h1a2 2 0 0 1 2 2 2 2 0 0 1 2-2h1 M9 6v12",
        ["trash-2"] = "M10 11v6 M14 11v6 M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6 M3 6h18 M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
        ["type"] = "M12 4v16 M4 7V5a1 1 0 0 1 1-1h14a1 1 0 0 1 1 1v2 M9 20h6",
        ["upload"] = "M12 3v12 M17 8 l-5-5-5 5 M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4",
        ["wand-sparkles"] = "M21.64 3.64 l-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72 M14 7 l 3 3 M5 6v4 M19 14v4 M10 2v2 M7 8H3 M21 16h-4 M11 3H9",
        ["wifi"] = "M12 20h.01 M2 8.82a15 15 0 0 1 20 0 M5 12.859a10 10 0 0 1 14 0 M8.5 16.429a5 5 0 0 1 7 0",
        ["wrap-text"] = "M16 16 l-3 3 3 3 M3 12h14.5a1 1 0 0 1 0 7H13 M3 19h6 M3 5h18",
        ["x"] = "M18 6 6 18 M6 6 l 12 12",
        ["zap"] = "M15.914 4a1.5 1.5 0 00-2.474-1.561l-9 9A1.5 1.5 0 005.5 14h4.002a.5.5 0 01.471.666L8.086 20a1.5 1.5 0 002.475 1.56l9-9A1.5 1.5 0 0018.5 10h-3.997a.5.5 0 01-.472-.667z",
        // Hand-authored (Lucide has no eject glyph): triangle over a bar.
        ["eject"] = "M12 4 20 14H4Z M6 19h12",
    };

    // Synonyms and macOS SF-Symbol names → catalogue keys.
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["terminal"] = "square-terminal",
        ["trash"] = "trash-2",
        ["trash.fill"] = "trash-2",
        ["delete"] = "trash-2",
        ["pencil"] = "square-pen",
        ["edit"] = "square-pen",
        ["rename"] = "text-cursor-input",
        ["magnifyingglass"] = "search",
        ["find"] = "search",
        ["arrow.clockwise"] = "refresh-cw",
        ["refresh"] = "refresh-cw",
        ["reload"] = "refresh-cw",
        ["gearshape"] = "settings",
        ["gearshape.fill"] = "settings",
        ["gear"] = "settings",
        ["key"] = "key-round",
        ["key.fill"] = "key-round",
        ["doc"] = "file-text",
        ["doc.text"] = "file-text",
        ["doc.plaintext"] = "file-text",
        ["doc.on.doc"] = "copy",
        ["folder.fill"] = "folder",
        ["folder.badge.plus"] = "folder-plus",
        ["display"] = "monitor",
        ["desktopcomputer"] = "monitor",
        ["macwindow"] = "monitor",
        ["laptopcomputer"] = "laptop",
        ["server.rack"] = "server",
        ["externaldrive"] = "hard-drive",
        ["internaldrive"] = "hard-drive",
        ["bolt"] = "zap",
        ["bolt.horizontal.circle"] = "zap",
        ["bolt.fill"] = "zap",
        ["star.fill"] = "star",
        ["house.fill"] = "house",
        ["home"] = "house",
        ["antenna.radiowaves.left.and.right"] = "radio",
        ["dot.radiowaves.left.and.right"] = "radio",
        ["tablecells"] = "table",
        ["tablecells.fill"] = "table",
        ["cylinder.split.1x2"] = "database",
        ["point.3.connected.trianglepath.dotted"] = "network",
        ["shippingbox"] = "package",
        ["shippingbox.fill"] = "package",
        ["paintpalette"] = "palette",
        ["paintpalette.fill"] = "palette",
        ["eye.slash"] = "eye",
        ["play.fill"] = "play",
        ["wifi.slash"] = "wifi",
        ["network.badge.shield.half.filled"] = "network",
        ["globe.americas.fill"] = "globe",
        ["globe.europe.africa.fill"] = "globe",
        ["safari"] = "globe",
        ["chevron.left"] = "chevron-left",
        ["chevron.right"] = "chevron-right",
        ["chevron.up"] = "chevron-up",
        ["arrow.up.doc"] = "upload",
        ["arrow.down.doc"] = "download",
        ["square.and.arrow.up"] = "upload",
        ["square.and.arrow.down"] = "download",
        ["xmark"] = "x",
        ["checkmark"] = "check",
        ["clock.arrow.circlepath"] = "history",
        ["ellipsis"] = "ellipsis-vertical",
        ["textformat.size"] = "type",
        ["wand.and.stars"] = "wand-sparkles",
        ["arrow.up.forward.app"] = "external-link",
    };

    /// <summary>Returns the SVG path data for a catalogue key, synonym or SF-Symbol
    /// name, or <c>null</c> when the name isn't a known line icon (e.g. a raw emoji).</summary>
    public static string? Resolve(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var key = name.Trim();
        if (Paths.TryGetValue(key, out var direct)) return direct;
        if (Aliases.TryGetValue(key, out var canon) && Paths.TryGetValue(canon, out var aliased))
            return aliased;
        return null;
    }
}
