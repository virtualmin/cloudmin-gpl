/* Cloudmin statistics: Webmin widgets around uPlot charts with headline
   values, round axis steps, mirrored I/O and notices for missing readings. */
(function () {
    "use strict";
    const shared =
        window.cloudminStatisticsAssets ||
        (window.cloudminStatisticsAssets = {});
    const REFRESH = 10000;
    const UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
    const PERCENT_INCRS = [0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100];
    const LOAD_INCRS = [
        0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100, 200, 250, 500,
        1000
    ];
    // Each chart lists its metrics in series order; the second metric of a
    // mirrored chart is drawn below the zero line.
    const GROUPS = [
        // Guests add the share of time their vCPUs waited for the host.
        {
            name: "cpu",
            unit: "percent",
            metrics: ["cpu"],
            guest: ["cpu_wait"],
            area: true
        },
        // Load averages curve smoothly; only hosts have them.
        {
            name: "load",
            unit: "load",
            metrics: ["load_1", "load_5", "load_15"],
            host: true,
            smooth: true,
            area: true
        },
        {
            name: "memory",
            unit: "bytes",
            metrics: ["memory_used", "memory_allocated"],
            total: 1,
            area: true
        },
        {
            name: "disk",
            unit: "bytes/s",
            metrics: ["disk_read", "disk_write"],
            mirrored: true,
            kinds: ["disk", "block"]
        },
        {
            name: "network",
            unit: "bytes/s",
            metrics: ["network_receive", "network_transmit"],
            mirrored: true,
            kinds: ["nic", "uplink"]
        }
    ];

    // plotLibrary() also finds Webmin's global lexical uPlot declaration.
    function plotLibrary() {
        return typeof uPlot !== "undefined" ? uPlot : window.uPlot;
    }

    // assets(config) shares an in-flight load across panels and both themes.
    function assets(config) {
        // Add shared chart styles only when the surrounding theme has not
        // loaded them.
        if (!document.querySelector('link[href*="uplot.min.css"]')) {
            const css = document.createElement("link");
            css.rel = "stylesheet";
            css.href = config.css + "uplot.min.css";
            document.head.append(css);
        }
        // Reuse a library already supplied by Webmin or the theme.
        if (plotLibrary()) return Promise.resolve(plotLibrary());
        // Concurrent panels share one bounded script load and can retry a
        // failed load.
        if (!shared.promise) {
            shared.promise = new Promise((resolve, reject) => {
                let script = document.querySelector(
                    'script[src*="uplot.min.js"]'
                );
                const created = !script;
                script = script || document.createElement("script");
                const timeout = setTimeout(
                    () => reject(new Error("Chart library timed out")),
                    15000
                );
                script.addEventListener(
                    "load",
                    () => {
                        clearTimeout(timeout);
                        plotLibrary()
                            ? resolve(plotLibrary())
                            : reject(new Error("Chart library unavailable"));
                    },
                    {once: true}
                );
                script.addEventListener(
                    "error",
                    () => {
                        clearTimeout(timeout);
                        // Remove only scripts owned by this loader so a later
                        // attempt can replace them.
                        if (created) script.remove();
                        reject(new Error("Chart library unavailable"));
                    },
                    {once: true}
                );
                // Insert a new script only when no existing library load can
                // be reused.
                if (created) {
                    script.src = config.assets + "uplot.min.js";
                    document.head.append(script);
                }
            }).catch(error => {
                shared.promise = null;
                throw error;
            });
        }
        return shared.promise;
    }

    // text(template, ...values) substitutes $1, $2 in a language string.
    function text(template, ...values) {
        return String(template || "").replace(
            /\$(\d)/g,
            (match, n) => values[n - 1] ?? ""
        );
    }

    // unitIndex(value) chooses a readable binary unit for a byte count.
    function unitIndex(value) {
        let n = 0,
            v = Math.abs(value);
        while (v >= 1024 && n < UNITS.length - 1) {
            v /= 1024;
            n++;
        }
        return n;
    }

    // bytes(value, [suffix], [unit]) formats a size in binary units. A fixed
    // unit index keeps axis ticks consistent. Values in KiB or larger units use
    // at most one decimal below 100. Suffix defaults to empty and unit defaults
    // to automatic selection.
    function bytes(value, suffix = "", unit = null) {
        const n = unit == null ? unitIndex(value) : unit;
        const v = Math.abs(value) / 1024 ** n;
        const digits = n === 0 || v >= 100 ? 0 : 1;
        return (
            (value < 0 ? "-" : "") +
            v.toFixed(digits).replace(/\.0$/, "") +
            " " +
            UNITS[n] +
            suffix
        );
    }

    // number(value, unit) formats a reading in its metric unit; null stays
    // a dash.
    function number(value, unit) {
        // Unavailable or nonnumeric values must never look like zero.
        if (value == null || !Number.isFinite(value)) return "–";
        // Percentages and load averages have fixed precision for
        // readable headings.
        if (unit === "percent") return value.toFixed(1) + "%";
        // Load is a task count, not a percentage of CPU capacity.
        if (unit === "load") return value.toFixed(2);
        // Sizes use binary units without a rate suffix.
        if (unit === "bytes") return bytes(value);
        // Counter rates use the same binary units with a per-second suffix.
        if (unit === "bytes/s") return bytes(value, "/s");
        return String(Math.round(value * 10) / 10);
    }

    // byteIncrs() lists round tick steps for byte axes: 1, 2, 2.5 and 5 and
    // their multiples of ten in every binary unit.
    function byteIncrs() {
        const incrs = [];
        for (let unit = 0; unit < UNITS.length; unit++) {
            for (const base of [
                1, 2, 2.5, 5, 10, 20, 25, 50, 100, 200, 250, 500
            ]) {
                // Byte counts have no fractional-byte tick steps.
                if (unit === 0 && base % 1) continue;
                incrs.push(base * 1024 ** unit);
            }
        }
        return incrs;
    }

    // tickLabels(splits, unit) formats one axis in a shared unit, without a
    // sign for the mirrored half below zero.
    function tickLabels(splits, unit) {
        // Keep percent ticks in their natural scale instead of applying
        // byte units.
        if (unit === "percent") return splits.map(v => v + "%");
        // Round load labels to suppress floating-point formatting noise.
        if (unit === "load")
            return splits.map(v => String(Math.round(v * 100) / 100));
        const largest = Math.max(...splits.map(Math.abs), 0);
        const n = unitIndex(largest);
        return splits.map(v =>
            v === 0
                ? "0"
                : bytes(v, unit === "bytes/s" ? "/s" : "", n).replace(/^-/, "")
        );
    }

    // channels(color) resolves any CSS color the theme supplies to [r, g, b].
    function channels(color) {
        const ctx = (
            shared.canvas || (shared.canvas = document.createElement("canvas"))
        ).getContext("2d");
        ctx.fillStyle = "#000";
        ctx.fillStyle = color;
        const value = ctx.fillStyle;
        // Canvas normalizes opaque colors to hex on browsers that support
        // this form.
        if (value.startsWith("#"))
            return [1, 3, 5].map(i => parseInt(value.slice(i, i + 2), 16));
        // Accept an RGB serialization and fall back to black for
        // unsupported forms.
        const inner = /rgba?\(([^)]+)\)/.exec(value);
        return inner
            ? inner[1]
                  .split(",")
                  .slice(0, 3)
                  .map(part => parseFloat(part))
            : [0, 0, 0];
    }

    // withAlpha(color, alpha) adds transparency to a theme color.
    function withAlpha(color, alpha) {
        return "rgba(" + channels(color).join(", ") + ", " + alpha + ")";
    }

    // isDark(color) tells whether a surface color needs dark native controls.
    function isDark(color) {
        const [r, g, b] = channels(color);
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
    }

    // clock(t, [withDate], [withSeconds]) formats Unix seconds in local time.
    // Both flags default to false. WithDate includes the date without seconds.
    function clock(t, withDate, withSeconds) {
        const date = new Date(t * 1000);
        // Long windows need a date so identical clock times
        // remain distinguishable.
        if (withDate)
            return date.toLocaleString([], {
                month: "short",
                day: "numeric",
                hour: "numeric",
                minute: "2-digit"
            });
        return date.toLocaleTimeString([], {
            hour: "numeric",
            minute: "2-digit",
            ...(withSeconds ? {second: "2-digit"} : {})
        });
    }

    // timeLabels(u, splits, axis, space, incr) keeps axis ticks on one line:
    // times within a day, hours with their date beyond it, dates for
    // daily steps.
    function timeLabels(u, splits, axis, space, incr) {
        const span = (u.scales.x.max || 0) - (u.scales.x.min || 0);
        return splits.map(t => {
            const date = new Date(t * 1000);
            // Daily tick spacing needs dates without redundant clock times.
            if (incr >= 86400)
                return date.toLocaleDateString([], {
                    month: "short",
                    day: "numeric"
                });
            // Multi-day windows retain both the date and the hour.
            if (span > 86400 * 1.5)
                return date.toLocaleString([], {
                    month: "short",
                    day: "numeric",
                    hour: "numeric"
                });
            return date.toLocaleTimeString([], {
                hour: "numeric",
                minute: "2-digit"
            });
        });
    }

    // duration(seconds, labels) names a gap length in seconds, minutes, hours
    // or days.
    function duration(seconds, labels) {
        // Short gaps need seconds rather than rounded minutes.
        if (seconds < 120)
            return text(labels.seconds, Math.max(1, Math.round(seconds)));
        const minutes = Math.round(seconds / 60);
        // Use minutes until the gap reaches an hour.
        if (minutes < 60) return text(labels.minutes, minutes);
        const hours = Math.round(minutes / 60);
        // Use hours for gaps shorter than two days, with the singular form
        // for one.
        if (hours < 48)
            return hours === 1 ? labels.hour : text(labels.hours, hours);
        const days = Math.round(hours / 24);
        return days === 1 ? labels.day : text(labels.days, days);
    }

    // element(tag, [className], [content]) creates a node with safe
    // text content.
    function element(tag, className, content) {
        const node = document.createElement(tag);
        // An omitted class leaves the browser default styling intact.
        if (className) node.className = className;
        // Assign even empty or zero content as text, never as trusted markup.
        if (content != null) node.textContent = content;
        return node;
    }

    // liveValues(data, host) maps the collector's current readings to
    // metric names.
    function liveValues(data, host) {
        const live = data.live;
        // Do not treat absent or stale collector data as a current measurement.
        if (!live || !data.collector?.available) return {};
        // Host samples already use the normalized metric names.
        if (host || live.values) return live.values || {};
        const r = live.resources || {},
            g = live.guest || {};
        return {
            cpu: r.cpu_percent,
            cpu_wait: r.cpu_wait_percent,
            vcpus: r.vcpus,
            memory_allocated: r.memory_bytes,
            memory_used: r.memory_used_bytes,
            disk_read: r.disk_read_bytes_sec,
            disk_write: r.disk_write_bytes_sec,
            network_receive: r.network_rx_bytes_sec,
            network_transmit: r.network_tx_bytes_sec,
            filesystem_total: g.filesystem_total_bytes,
            filesystem_used: g.filesystem_used_bytes
        };
    }

    // summarize(rows, metric) returns a coverage-weighted mean, the latest
    // covered reading and the stored peak with its bucket start.
    function summarize(rows, metric) {
        let sum = 0,
            weight = 0,
            peak = null,
            peakAt = null,
            last = null;
        for (const row of rows) {
            const v = row.values[metric],
                w = row.coverage[metric] || 0;
            // Only measured buckets contribute to the mean or latest
            // covered value.
            if (v != null && w > 0) {
                sum += v * w;
                weight += w;
                last = v;
            }
            const p = row.peaks?.[metric];
            // Retain the first bucket holding the largest stored peak.
            if (p != null && (peak == null || p > peak)) {
                peak = p;
                peakAt = row.t;
            }
        }
        return {avg: weight > 0 ? sum / weight : null, peak, peakAt, last};
    }

    // gaps(rows, metric, [minimum]) lists stretches without valid readings
    // between the first and the last measured bucket, as [from, to] pairs.
    // Minimum defaults to zero. Shorter holes are left out: a brief one near a
    // bucket edge would otherwise flicker in and out as the period slides.
    function gaps(rows, metric, minimum = 0) {
        const covered = rows.map(row => (row.coverage[metric] || 0) >= 0.5);
        const first = covered.indexOf(true),
            last = covered.lastIndexOf(true);
        const result = [];
        let start = null;
        for (let i = first; first >= 0 && i <= last; i++) {
            // Start a gap at the first bucket with less than half its
            // interval measured.
            if (!covered[i]) {
                if (start == null) start = rows[i].t;
            }
            // Close a gap only when measurements resume, excluding trailing
            // empty history.
            else if (start != null) {
                result.push([start, rows[i].t]);
                start = null;
            }
        }
        return result.filter(([a, b]) => b - a >= minimum);
    }

    // gapNotice(list, template, labels, withDate) describes gaps by length
    // and time.
    function gapNotice(list, template, labels, withDate) {
        const seconds = list.reduce((sum, [a, b]) => sum + (b - a), 0);
        // Short gaps need seconds, or their start and end would read alike.
        const when =
            list
                .slice(0, 3)
                .map(
                    ([a, b]) =>
                        clock(a, withDate, b - a < 120) +
                        " – " +
                        clock(b, withDate, b - a < 120)
                )
                .join(", ") + (list.length > 3 ? ", …" : "");
        return text(template, duration(seconds, labels), when);
    }

    // mount(root) owns chart requests, observers and cleanup for one
    // page panel.
    function mount(root) {
        // SPA navigation can encounter the same panel more than once.
        if (root.dataset.statisticsMounted) return;
        root.dataset.statisticsMounted = "1";
        const config = JSON.parse(root.dataset.statistics);
        const host = config.owner === "host";
        const labels = config.labels;
        const toolbar = root.querySelector(".cloudmin-statistics-toolbar");
        const customBox = root.querySelector(".cloudmin-statistics-custom");
        const device = root.querySelector('[name="statistics_device"]');
        const deviceControl = root.querySelector(".cloudmin-statistics-device");
        // Keep stable references for loading, freshness and warning updates.
        const status = root.querySelector(".cloudmin-statistics-status");
        const countdown = root.querySelector(".cloudmin-statistics-countdown");
        const countdownFill = root.querySelector(
            ".cloudmin-statistics-countdown-fill"
        );
        const notice = root.querySelector(".cloudmin-statistics-notice");
        const grid = root.querySelector(".cloudmin-statistics-charts");
        // Storage and event cards have their own empty and
        // failed-request states.
        const mounts = root.querySelector(".cloudmin-statistics-mounts");
        const change = root.querySelector(".cloudmin-statistics-change");
        const changes = root.querySelector(".cloudmin-statistics-changes");
        const events = root.querySelector(".cloudmin-statistics-events");
        const eventSummary = root.querySelector(
            ".cloudmin-statistics-events-summary"
        );
        // Keep at most 600 session readings when persistent history
        // is unavailable.
        const live = [];
        const entries = GROUPS.filter(group => !group.host || host).map(
            group => {
                // Guests extend the CPU chart with host scheduling delay.
                if (!host && group.guest)
                    group = {
                        ...group,
                        metrics: [...group.metrics, ...group.guest]
                    };
                const parent = root.querySelector(
                    '.cloudmin-statistics-plot[data-chart="' + group.name + '"]'
                );
                const card = parent.closest(".cloudmin-statistics-chart");
                return {
                    group,
                    parent,
                    card,
                    empty: parent.querySelector(".cloudmin-statistics-empty"),
                    value: card.querySelector(".cloudmin-statistics-value"),
                    detail: card.querySelector(".cloudmin-statistics-detail"),
                    bar: card.querySelector(".cloudmin-statistics-bar-fill"),
                    chart: null,
                    data: null,
                    total: null
                };
            }
        );
        // The panel owns its active request, polling timer and shared
        // zoom window.
        let request,
            timer,
            eventState,
            destroyed = false,
            active = false,
            zoom = null,
            sampling = 0;
        let period = periodValue();
        const style = getComputedStyle(root);
        const colors = [
            style.getPropertyValue("--cloudmin-series-1").trim() || "#4c8ee8",
            style.getPropertyValue("--cloudmin-series-2").trim() || "#e0952f",
            style.getPropertyValue("--cloudmin-series-3").trim() || "#8b6fd6"
        ];
        // Canvas colors must follow palette changes after the page loads.
        const palette = {};
        const paletteObserver = new MutationObserver(repaint);
        const colorScheme = window.matchMedia("(prefers-color-scheme: dark)");
        // Resize existing plots when their cards change size without
        // rebuilding them.
        const resize = new ResizeObserver(() =>
            entries.forEach(entry => {
                // Hidden or not-yet-created charts have no usable width
                // to resize.
                if (entry.chart && entry.parent.clientWidth)
                    entry.chart.setSize({
                        width: entry.parent.clientWidth,
                        height: plotHeight()
                    });
            })
        );

        // stickyLayout() keeps the toolbar below sticky headers.
        function stickyLayout() {
            let offset = 0,
                background = "";
            for (
                let node = toolbar;
                node && node !== document.documentElement;
                node = node.parentElement
            ) {
                for (
                    let prev = node.previousElementSibling;
                    prev;
                    prev = prev.previousElementSibling
                ) {
                    const style = getComputedStyle(prev);
                    // Leave room for each sticky header above.
                    if (style.position === "sticky")
                        offset +=
                            prev.getBoundingClientRect().height +
                            (parseFloat(style.top) || 0);
                }
                // Use the nearest nontransparent ancestor's background.
                const color =
                    node === toolbar
                        ? ""
                        : getComputedStyle(node).backgroundColor;
                if (
                    !background &&
                    color &&
                    !/^(transparent|rgba\(.*,\s*0\))$/.test(color)
                )
                    background = color;
            }
            toolbar.style.setProperty("--cloudmin-sticky-top", offset + "px");
            // Cover scrolled charts with the page background.
            if (background)
                toolbar.style.setProperty("--cloudmin-sticky-bg", background);
            // Use the CSS fallback when no ancestor has a background.
            else toolbar.style.removeProperty("--cloudmin-sticky-bg");
        }

        // repaint() applies colors without fetching data or resetting zoom.
        function repaint() {
            const style = getComputedStyle(root);
            palette.muted =
                style.getPropertyValue("--ui-fg-muted").trim() || "#6b7280";
            palette.surface =
                style.getPropertyValue("--ui-surface").trim() || "#fff";
            root.style.colorScheme = isDark(palette.surface) ? "dark" : "light";
            stickyLayout();
            // Reuse each plot's paths and axes when repainting its colors.
            entries.forEach(entry => {
                // Loading and failed requests may leave a card without a chart.
                if (!entry.chart) return;
                entry.chart.redraw(false, false);
                // Match the tooltip's total marker to the repainted line.
                if (entry.tip) updateTooltip(entry.chart, entry, palette.muted);
            });
        }

        // plotHeight() reads the layout's plot height from the stylesheet.
        function plotHeight() {
            return (
                parseInt(
                    getComputedStyle(root).getPropertyValue(
                        "--cloudmin-plot-height"
                    ),
                    10
                ) || 190
            );
        }

        // startCountdown() animates the time remaining until the next refresh.
        // A CSS transition avoids needing a separate countdown timer.
        function startCountdown() {
            countdown.hidden = !sampling;
            // No current sampling status means there is no meaningful
            // refresh countdown.
            if (!sampling) return;
            countdownFill.style.transition = "none";
            countdownFill.style.width = "100%";
            void countdownFill.offsetWidth;
            countdownFill.style.transition = "width " + REFRESH + "ms linear";
            countdownFill.style.width = "0";
        }

        // periodValue() returns the checked period segment.
        function periodValue() {
            return (
                root.querySelector('[name="statistics_range"]:checked')
                    ?.value || "3600"
            );
        }

        // moment(prefix) returns the date and time fields of one custom
        // range end.
        function moment(prefix) {
            return ["date", "time"].map(part =>
                root.querySelector('[name="' + prefix + "_" + part + '"]')
            );
        }

        // momentDate(text) parses "YYYY-MM-DD HH:MM" in local time, or
        // returns null.
        function momentDate(text) {
            const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec(
                String(text || "").trim()
            );
            return m ? new Date(+m[1], m[2] - 1, +m[3], +m[4], +m[5]) : null;
        }

        // setMoment(prefix, t) fills the fields in local time, rounded down to
        // the quarter hour. A theme calendar with its own clock holds
        // both parts.
        function setMoment(prefix, t) {
            const d = new Date(t * 1000);
            // pad(n) keeps local date and time components two digits wide.
            const pad = n => String(n).padStart(2, "0");
            const [date, time] = moment(prefix);
            const day =
                d.getFullYear() +
                "-" +
                pad(d.getMonth() + 1) +
                "-" +
                pad(d.getDate());
            const clock =
                pad(d.getHours()) +
                ":" +
                pad(Math.floor(d.getMinutes() / 15) * 15);
            // A theme calendar stores both parts in the visible date field.
            if (time.hidden) date.value = day + " " + clock;
            // Native controls keep the local date and time in separate fields.
            else {
                date.value = day;
                time.value = clock;
            }
        }

        // readMoment(prefix) converts the fields to Unix seconds, or NaN
        // when incomplete.
        function readMoment(prefix) {
            const [date, time] = moment(prefix);
            const value = time.hidden
                ? momentDate(date.value)
                : date.value && time.value
                  ? new Date(date.value + "T" + time.value)
                  : null;
            return value ? Math.floor(value.getTime() / 1000) : NaN;
        }

        // themePicker() returns the theme's optional calendar API.
        // The theme object may be lexical rather than a window property.
        function themePicker() {
            const api = typeof theme !== "undefined" ? theme : window.theme;
            const picker = api?.api?.datepicker;
            return picker &&
                typeof picker.create === "function" &&
                picker.available?.()
                ? picker
                : null;
        }

        // currentRange() returns the requested period, or null for an invalid
        // custom range.
        function currentRange() {
            const now = Math.floor(Date.now() / 1000);
            // Custom windows use explicit local dates rather than a moving
            // lookback period.
            if (periodValue() === "custom") {
                const from = readMoment("statistics_from"),
                    to = readMoment("statistics_to");
                // Reject incomplete, reversed or excessively long windows
                // before requesting data.
                if (
                    !Number.isFinite(from) ||
                    !Number.isFinite(to) ||
                    from >= to ||
                    to - from > 366 * 86400
                )
                    return null;
                return {from, to: Math.min(to, now + 60), custom: true};
            }
            return {from: now - Number(periodValue()), to: now};
        }

        // periodText(data) labels the selected range for summaries.
        function periodText(data) {
            // Custom ranges show both endpoints.
            if (periodValue() === "custom")
                return text(
                    labels.between,
                    clock(data.from, true),
                    clock(data.to, true)
                );
            const span = data.to - data.from;
            return span <= 3600
                ? labels.last_hour
                : text(labels.last, duration(span, labels));
        }

        // clear() releases charts when leaving the page or losing API access.
        function clear() {
            resize.disconnect();
            entries.forEach(entry => {
                entry.chart?.destroy();
                entry.chart = null;
                entry.parent.querySelector(".uplot")?.remove();
            });
        }

        // chartRange(data) preserves a shared zoom as the live period advances.
        function chartRange(data) {
            // Unzoomed charts follow the entire selected window as it advances.
            if (!zoom) return [data.from, data.to];
            const span = Math.min(zoom.max - zoom.min, data.to - data.from);
            const min = Math.max(data.from, Math.min(zoom.min, data.to - span));
            return [min, min + span];
        }

        // setZoom(value) applies one time window to every chart; null restores
        // the period.
        function setZoom(value) {
            zoom = value;
            entries.forEach(entry => {
                // Skip plots that have not loaded or were cleared after a
                // failed request.
                if (!entry.chart) return;
                const [min, max] = chartRange(entry.data);
                entry.chart.setScale("x", {min, max});
            });
        }

        // wheelPixels(event, value) normalizes a wheel delta to pixels.
        function wheelPixels(event, value) {
            // Line-based wheel events use a consistent approximate text
            // line height.
            if (event.deltaMode === 1) return value * 16;
            // Page-based wheel events scale with the current viewport height.
            if (event.deltaMode === 2)
                return value * (window.innerHeight || 800);
            return value;
        }

        // pan(entry, pixels) slides the shared zoom window by a
        // pointer distance.
        function pan(entry, pixels) {
            // Panning applies only after zooming a loaded chart.
            if (!zoom || !entry.chart) return false;
            const [min, max] = chartRange(entry.data);
            const span = max - min;
            // A full-width window has no hidden period to pan into.
            if (span >= (entry.data.to - entry.data.from) * 0.999) return false;
            const width =
                entry.chart.over.getBoundingClientRect().width ||
                entry.chart.width ||
                1;
            const low = Math.max(
                entry.data.from,
                Math.min(min + span * (pixels / width), entry.data.to - span)
            );
            setZoom({min: low, max: low + span});
            return true;
        }

        // bindZoom(entry) zooms around the pointer with Shift-wheel and, once
        // zoomed, pans with a sideways wheel or a drag.
        function bindZoom(entry) {
            entry.zoomEvents?.abort();
            const controller = (entry.zoomEvents = new AbortController());
            let drag = null;
            entry.parent.addEventListener(
                "wheel",
                event => {
                    // Browser zoom and empty charts retain their
                    // normal behavior.
                    if (
                        event.ctrlKey ||
                        event.metaKey ||
                        !entry.chart ||
                        entry.parent.classList.contains(
                            "cloudmin-statistics-plot-empty"
                        ) ||
                        entry.parent.classList.contains(
                            "cloudmin-statistics-plot-loading"
                        )
                    )
                        return;
                    const deltaX = wheelPixels(event, event.deltaX),
                        deltaY = wheelPixels(event, event.deltaY);
                    // Without Shift only a sideways wheel acts, panning a
                    // zoomed chart.
                    if (!event.shiftKey) {
                        // Intercept sideways scrolling only when the zoomed
                        // window can be panned.
                        if (
                            Math.abs(deltaX) > Math.abs(deltaY) &&
                            deltaX &&
                            pan(entry, deltaX)
                        ) {
                            event.preventDefault();
                            event.stopPropagation();
                        }
                        return;
                    }
                    const delta =
                        Math.abs(deltaX) > Math.abs(deltaY) ? deltaX : deltaY;
                    // A zero wheel delta should not consume ordinary
                    // browser input.
                    if (!delta) return;
                    event.preventDefault();
                    event.stopPropagation();
                    // Anchor zoom at the pointer and clamp that anchor to the
                    // plot bounds.
                    const [min, max] = chartRange(entry.data);
                    const rect = entry.chart.over.getBoundingClientRect();
                    const ratio = rect.width
                        ? Math.max(
                              0,
                              Math.min(
                                  1,
                                  (event.clientX - rect.left) / rect.width
                              )
                          )
                        : 0.5;
                    const full = entry.data.to - entry.data.from;
                    // Do not magnify beyond a few stored points or outside
                    // this period.
                    const step = Math.max(
                        entry.data.bucket_seconds || 0,
                        entry.data.resolution || 0,
                        entry.data.collector?.interval || 10
                    );
                    const span = Math.min(
                        full,
                        Math.max(
                            4 * step,
                            10,
                            (max - min) *
                                Math.pow(
                                    1.14,
                                    Math.max(-1, Math.min(1, delta / 100))
                                )
                        )
                    );
                    const low = Math.max(
                        entry.data.from,
                        Math.min(
                            min + (max - min - span) * ratio,
                            entry.data.to - span
                        )
                    );
                    setZoom(
                        span >= full * 0.999
                            ? null
                            : {min: low, max: low + span}
                    );
                },
                {passive: false, signal: controller.signal}
            );
            entry.parent.addEventListener(
                "dblclick",
                () => {
                    // Double-click restores the full selected period across
                    // all charts.
                    if (zoom) setZoom(null);
                },
                {signal: controller.signal}
            );
            // Dragging a zoomed chart moves the window with the pointer.
            entry.parent.addEventListener(
                "pointerdown",
                event => {
                    // Only a primary-button drag on a zoomed chart captures
                    // the pointer.
                    if (!zoom || event.button !== 0 || !entry.chart) return;
                    drag = {
                        x: event.clientX,
                        range: chartRange(entry.data),
                        id: event.pointerId
                    };
                    try {
                        entry.parent.setPointerCapture(event.pointerId);
                    } catch (error) {
                        /* synthetic pointers */
                    }
                    event.preventDefault();
                },
                {signal: controller.signal}
            );
            entry.parent.addEventListener(
                "pointermove",
                event => {
                    // Ignore unrelated pointers or a chart cleared during
                    // the drag.
                    if (!drag || event.pointerId !== drag.id || !entry.chart)
                        return;
                    const width =
                        entry.chart.over.getBoundingClientRect().width || 1;
                    const span = drag.range[1] - drag.range[0];
                    const low = Math.max(
                        entry.data.from,
                        Math.min(
                            drag.range[0] -
                                span * ((event.clientX - drag.x) / width),
                            entry.data.to - span
                        )
                    );
                    setZoom({min: low, max: low + span});
                },
                {signal: controller.signal}
            );
            // release(event) ends only the drag belonging to this pointer.
            const release = event => {
                // Another pointer must not release an active chart drag.
                if (!drag || event.pointerId !== drag.id) return;
                drag = null;
                try {
                    entry.parent.releasePointerCapture(event.pointerId);
                } catch (error) {
                    /* already released */
                }
            };
            entry.parent.addEventListener("pointerup", release, {
                signal: controller.signal
            });
            entry.parent.addEventListener("pointercancel", release, {
                signal: controller.signal
            });
        }

        // updateDevices(entities) offers a filter only for multiple disks or
        // NICs. Returns true when the current selection needs a fresh
        // aggregate query.
        function updateDevices(entities) {
            const selected = device.value;
            const disks = entities.filter(item =>
                ["disk", "block"].includes(item.kind)
            );
            const networks = entities.filter(item =>
                ["nic", "uplink"].includes(item.kind)
            );
            const visible = disks.length > 1 || networks.length > 1;
            const options = [
                ["", labels.all],
                ...(visible ? [...disks, ...networks] : []).map(item => [
                    item.id,
                    item.label + " (" + item.kind + ")"
                ])
            ];
            // Keep an open device menu intact unless its choices change.
            if (
                JSON.stringify(options) !==
                JSON.stringify(
                    [...device.options].map(option => [
                        option.value,
                        option.text
                    ])
                )
            ) {
                device.replaceChildren(
                    ...options.map(([value, label]) => new Option(label, value))
                );
            }
            device.value = options.some(([value]) => value === selected)
                ? selected
                : "";
            deviceControl.hidden = !visible;
            return device.value !== selected;
        }

        // visibleGroups(data) hides every chart but the one a device filter
        // applies to.
        function visibleGroups(data) {
            const kind = (data.entities || []).find(
                item => item.id === device.value
            )?.kind;
            const shown = entries.filter(
                entry => !kind || (entry.group.kinds || []).includes(kind)
            );
            entries.forEach(entry => {
                entry.card.hidden = !shown.includes(entry);
            });
            grid.classList.toggle("cloudmin-statistics-single", !!kind);
            // A device-only chart omits unrelated host pools or
            // guest filesystems.
            if (mounts)
                mounts.closest(".cloudmin-statistics-filesystems").hidden =
                    !!kind;
            return {shown, kind};
        }

        // chartOptions(entry, Plot) builds the uPlot options for one chart.
        function chartOptions(entry, Plot) {
            const group = entry.group;
            // muted() supplies the current text color to uPlot on each repaint.
            const muted = () => palette.muted;
            const fontFamily = getComputedStyle(root).fontFamily;
            const font = "11px " + fontFamily;
            const scale = {};
            // Mirrored charts share one symmetric axis around zero.
            if (group.mirrored) {
                scale.range = (u, min, max) => {
                    const m =
                        Math.max(Math.abs(min || 0), Math.abs(max || 0), 1024) *
                        1.1;
                    return [-m, m];
                };
            }
            // Low CPU activity stays legible while the axis remains bounded
            // by 100%.
            else if (group.unit === "percent") {
                scale.range = (u, min, max) => [
                    0,
                    Math.max(5, Math.min(100, (max || 0) * 1.15))
                ];
            }
            // Load has no percentage ceiling, but its empty scale needs a
            // usable range.
            else if (group.unit === "load") {
                scale.range = (u, min, max) => [
                    0,
                    Math.max(1, (max || 0) * 1.15)
                ];
            }
            // Capacity charts include their total and leave a little space
            // above it.
            else {
                scale.range = (u, min, max) => [
                    0,
                    Math.max(entry.total || 0, max || 0) * 1.06 || 1
                ];
            }
            // Use the theme font and unit-specific tick spacing on a compact
            // value axis.
            const valueAxis = {
                stroke: muted,
                font,
                size: 62,
                gap: 6,
                ticks: {show: false},
                grid: {stroke: "rgba(128,128,128,.16)", width: 1},
                incrs:
                    group.unit === "percent"
                        ? PERCENT_INCRS
                        : group.unit === "load"
                          ? LOAD_INCRS
                          : byteIncrs(),
                values: (u, splits) => tickLabels(splits, group.unit)
            };
            const series = [{}];
            group.metrics.forEach((metric, i) => {
                const total = group.total === i;
                // Smooth charts curve through their points, with the leading
                // series heavier and shaded and the longer averages behind it.
                series.push({
                    label: metric,
                    stroke: total ? muted : colors[i],
                    width: total ? 1 : i && group.smooth ? 1.2 : 1.5,
                    dash: total ? [4, 4] : undefined,
                    spanGaps: false,
                    points: {show: false},
                    paths: group.smooth ? Plot.paths.spline() : undefined,
                    fill:
                        total || !((group.area && i === 0) || group.mirrored)
                            ? undefined
                            : withAlpha(colors[i], 0.15),
                    value: (u, v) =>
                        number(v == null ? v : Math.abs(v), group.unit)
                });
            });
            // Use custom pan and zoom handlers and a tooltip instead of
            // uPlot's legend.
            return {
                width: entry.parent.clientWidth || 500,
                height: plotHeight(),
                padding: [12, 10, 0, 0],
                cursor: {
                    drag: {x: false, y: false},
                    x: true,
                    y: false,
                    points: {
                        size: 7,
                        width: 2,
                        fill: () => "#fff",
                        stroke: (u, i) => u.series[i].stroke
                    }
                },
                legend: {show: false},
                scales: {x: {range: () => chartRange(entry.data)}, y: scale},
                axes: [
                    {
                        stroke: muted,
                        font,
                        gap: 5,
                        size: 26,
                        space: 76,
                        ticks: {show: false},
                        grid: {show: false},
                        values: timeLabels
                    },
                    valueAxis
                ],
                series,
                hooks: {
                    // Labels and tooltips use the current palette too.
                    draw: [
                        u =>
                            drawOverlay(
                                u,
                                entry,
                                palette.muted,
                                palette.surface,
                                fontFamily
                            )
                    ],
                    setCursor: [u => updateTooltip(u, entry, palette.muted)],
                    destroy: [
                        () => {
                            entry.zoomEvents?.abort();
                            entry.tip = null;
                        }
                    ]
                }
            };
        }

        // drawOverlay(u, entry, muted, surface, fontFamily) adds event lines,
        // the peak marker, the total line label and the read/write side labels.
        function drawOverlay(u, entry, muted, surface, fontFamily) {
            const group = entry.group,
                ctx = u.ctx,
                dpr = devicePixelRatio || 1;
            const {left, top, width, height} = u.bbox;
            // Clip overlays to the plot and restore canvas state before uPlot
            // draws again.
            ctx.save();
            ctx.beginPath();
            ctx.rect(left, top, width, height);
            ctx.clip();
            ctx.strokeStyle = "rgba(160,120,70,.45)";
            ctx.lineWidth = 1;
            ctx.setLineDash([3 * dpr, 3 * dpr]);
            (entry.data.events || []).forEach(event => {
                const x = u.valToPos(event.t, "x", true);
                // Do not draw event markers outside the current zoom window.
                if (x < left || x > left + width) return;
                ctx.beginPath();
                ctx.moveTo(x, top);
                ctx.lineTo(x, top + height);
                ctx.stroke();
            });
            ctx.setLineDash([]);
            ctx.font = 11 * dpr + "px " + fontFamily;
            ctx.textAlign = "right";
            // caption(label, y, baseline) pads a label with the theme
            // surface color.
            const caption = (label, y, baseline) => {
                const w = ctx.measureText(label).width,
                    h = 12 * dpr;
                const boxTop =
                    baseline === "top" ? y - 1 * dpr : y - h + 1 * dpr;
                ctx.globalAlpha = 0.85;
                ctx.fillStyle = surface;
                ctx.fillRect(
                    left + width - 6 * dpr - w,
                    boxTop,
                    w + 4 * dpr,
                    h
                );
                ctx.globalAlpha = 1;
                ctx.fillStyle = muted;
                ctx.textBaseline = baseline;
                ctx.fillText(label, left + width - 4 * dpr, y);
            };
            // Ring the highest plotted value in the main series. Stored bucket
            // peaks used by the headline can be higher than these averages.
            const values = u.data[1] || [];
            let peak = -1;
            // Ignore missing values and keep the earliest plotted maximum.
            values.forEach((v, i) => {
                if (v != null && (peak < 0 || v > values[peak])) peak = i;
            });
            // No marker is needed for an empty or all-zero series.
            if (peak >= 0 && values[peak] > 0) {
                const x = u.valToPos(u.data[0][peak], "x", true),
                    y = u.valToPos(values[peak], "y", true);
                // Draw the marker only when that maximum lies inside the
                // zoom window.
                if (x >= left && x <= left + width) {
                    ctx.beginPath();
                    ctx.arc(x, y, 3.5 * dpr, 0, Math.PI * 2);
                    ctx.fillStyle = "#fff";
                    ctx.fill();
                    ctx.lineWidth = 1.5 * dpr;
                    ctx.strokeStyle = colors[0];
                    ctx.stroke();
                }
            }
            // Captions come last, so a peak in a corner cannot hide their text.
            if (group.mirrored) {
                caption(
                    labels[
                        group.metrics[0] === "disk_read" ? "read" : "receive"
                    ].toLowerCase(),
                    top + 3 * dpr,
                    "top"
                );
                caption(
                    labels[
                        group.metrics[1] === "disk_write" ? "write" : "transmit"
                    ].toLowerCase(),
                    top + height - 3 * dpr,
                    "bottom"
                );
            }
            // Capacity charts label their total instead of mirrored
            // traffic directions.
            else if (group.total != null && entry.total) {
                caption(
                    labels.total.toLowerCase() + " " + bytes(entry.total),
                    u.valToPos(entry.total, "y", true) + 3 * dpr,
                    "top"
                );
            }
            ctx.restore();
        }

        // updateTooltip(u, entry, muted) shows the hovered time and readings
        // beside the cursor.
        function updateTooltip(u, entry, muted) {
            const group = entry.group;
            let tip = entry.tip;
            // Create one tooltip per plot and reuse it as the cursor moves.
            if (!tip) {
                tip = entry.tip = element("div", "cloudmin-statistics-tooltip");
                tip.hidden = true;
                u.over.append(tip);
            }
            const idx = u.cursor.idx;
            // Hide the tooltip when no plotted sample is under the cursor.
            if (idx == null || u.cursor.left < 0 || !u.data[0].length) {
                tip.hidden = true;
                return;
            }
            const withDate = entry.data.to - entry.data.from > 86400;
            tip.replaceChildren(
                element(
                    "div",
                    "cloudmin-statistics-tooltip-time",
                    clock(u.data[0][idx], withDate)
                )
            );
            group.metrics.forEach((metric, i) => {
                const row = element("div", "cloudmin-statistics-tooltip-row");
                const dot = element("i", "cloudmin-statistics-dot");
                // Match the dashed capacity line in the tooltip key.
                if (group.total === i) {
                    dot.style.background = "transparent";
                    dot.style.border = "1px dashed " + muted;
                }
                // Measured series keep their assigned chart color.
                else dot.style.background = colors[i];
                const v = u.data[i + 1][idx];
                row.append(
                    dot,
                    element("span", "", seriesLabel(group, i)),
                    element(
                        "b",
                        "",
                        number(v == null ? v : Math.abs(v), group.unit)
                    )
                );
                tip.append(row);
            });
            tip.hidden = false;
            const rect = u.over.getBoundingClientRect();
            let x = u.cursor.left + 14;
            // Move the tooltip left when placing it to the right would clip
            // its text.
            if (x + tip.offsetWidth > rect.width)
                x = Math.max(0, u.cursor.left - tip.offsetWidth - 14);
            const y = Math.max(
                0,
                Math.min(
                    rect.height - tip.offsetHeight,
                    u.cursor.top - tip.offsetHeight / 2
                )
            );
            tip.style.transform = "translate(" + x + "px, " + y + "px)";
        }

        // seriesLabel(group, index) names a series with the chart's
        // legend words.
        function seriesLabel(group, index) {
            const keys = {
                cpu: "cpu",
                cpu_wait: "cpu_wait",
                memory_used: "used",
                memory_allocated: "total",
                disk_read: "read",
                disk_write: "write",
                network_receive: "receive",
                network_transmit: "transmit",
                load_1: "load_1",
                load_5: "load_5",
                load_15: "load_15"
            };
            return labels[keys[group.metrics[index]]] || group.metrics[index];
        }

        // headline(entry, rows, current, kind) fills a card from live or device
        // data. Kind is undefined for totals. CPU also shows the
        // coverage-weighted mean, while every chart can show its stored
        // period peak.
        function headline(entry, rows, current, kind) {
            const group = entry.group,
                unit = group.unit;
            const withDate = entry.data.to - entry.data.from > 86400;
            const stats = group.metrics.map(metric => summarize(rows, metric));
            const parts = [];
            let value = null;
            // Show combined traffic with both directions and the larger
            // directional peak.
            if (group.mirrored) {
                const [a, b] = group.metrics.map((metric, i) =>
                    kind ? stats[i].last : current[metric]
                );
                value = a == null && b == null ? null : (a || 0) + (b || 0);
                parts.push(
                    seriesLabel(group, 0) + " " + number(a, unit),
                    seriesLabel(group, 1) + " " + number(b, unit)
                );
                const top =
                    stats[0].peak != null &&
                    (stats[1].peak == null || stats[0].peak >= stats[1].peak)
                        ? 0
                        : 1;
                // An unmeasured direction must not invent a zero peak.
                if (stats[top].peak != null) {
                    parts.push(
                        text(
                            labels.peak_at,
                            number(stats[top].peak, unit) +
                                " " +
                                seriesLabel(group, top).toLowerCase(),
                            clock(stats[top].peakAt, withDate)
                        )
                    );
                }
            }
            // Memory shows used capacity and any known total independently.
            else if (group.total != null) {
                const used = kind ? stats[0].last : current.memory_used;
                const total = current.memory_allocated ?? stats[1].last;
                value = used;
                // Calculate a percentage only when both capacity and usage
                // are known.
                if (total && used != null)
                    parts.push(
                        text(
                            labels.of,
                            bytes(total),
                            Math.round((100 * used) / total)
                        )
                    );
                // A known total does not establish the missing
                // usage percentage.
                else if (total) parts.push(text(labels.of, bytes(total), "–"));
                // Compare running guests' memory allocations with the
                // host total.
                if (host && current.guest_memory != null)
                    parts.push(
                        text(
                            labels.memory_allocated,
                            bytes(current.guest_memory)
                        )
                    );
                // Keep the stored memory peak even when the current reading
                // is unavailable.
                if (stats[0].peak != null)
                    parts.push(
                        text(
                            labels.peak_at,
                            bytes(stats[0].peak),
                            clock(stats[0].peakAt, withDate)
                        )
                    );
                // Clamp only the visual memory bar to its track.
                if (entry.bar)
                    entry.bar.style.width =
                        total && used != null
                            ? Math.min(100, (100 * used) / total) + "%"
                            : "0";
            } else if (group.unit === "load") {
                // The one-minute load leads; the longer averages follow it.
                // now(i) chooses live load or the last covered value for a
                // device view.
                const now = i =>
                    kind ? stats[i].last : current[group.metrics[i]];
                value = now(0);
                // Only available five- and fifteen-minute readings appear
                // beside the main load.
                [1, 2].forEach(i => {
                    if (now(i) != null)
                        parts.push(
                            seriesLabel(group, i) + " " + number(now(i), unit)
                        );
                });
                // The stored peak remains useful even without a
                // current reading.
                if (stats[0].peak != null)
                    parts.push(
                        text(
                            labels.peak_at,
                            number(stats[0].peak, unit),
                            clock(stats[0].peakAt, withDate)
                        )
                    );
            }
            // CPU combines current utilization with capacity and available
            // history summaries.
            else {
                value = kind ? stats[0].last : current.cpu;
                // The host's logical CPU count provides context for
                // overall utilization.
                if (host && current.vcpus)
                    parts.push(
                        current.vcpus === 1
                            ? labels.cpu1
                            : text(labels.cpus, current.vcpus)
                    );
                // Guest allocations appear only when the collector has a
                // complete inventory.
                if (host && current.guest_vcpus != null)
                    parts.push(
                        text(labels.vcpus_allocated, current.guest_vcpus)
                    );
                // A guest's wait for the host reads beside its usage.
                const waiting =
                    group.metrics[1] === "cpu_wait"
                        ? kind
                            ? stats[1].last
                            : current.cpu_wait
                        : null;
                // Missing scheduler-delay counters omit the wait figure rather
                // than showing zero.
                if (waiting != null)
                    parts.push(text(labels.waiting, number(waiting, unit)));
                // Do not display a mean when the period has no measured
                // CPU coverage.
                if (stats[0].avg != null)
                    parts.push(text(labels.avg, number(stats[0].avg, unit)));
                // The stored peak remains useful even without a
                // current reading.
                if (stats[0].peak != null)
                    parts.push(
                        text(
                            labels.peak_at,
                            number(stats[0].peak, unit),
                            clock(stats[0].peakAt, withDate)
                        )
                    );
            }
            entry.value.textContent = number(value, unit);
            entry.detail.textContent = parts.join(" · ");
        }

        // drawMounts(data, rows) lists the guest's filesystems, or the host's
        // storage pools, as current usage bars. Its change sentence compares
        // the first and last available aggregate values in the period.
        function drawMounts(data, rows) {
            // Pages without a storage card need no mount or pool rendering.
            if (!mounts) return;
            const list = (
                host
                    ? (data.live?.pools || []).map(pool => ({
                          label: pool.name,
                          detail: pool.target || pool.type || "",
                          total: pool.capacity,
                          used: pool.allocation
                      }))
                    : (data.live?.guest?.filesystems || []).map(fs => ({
                          label: fs.mountpoint || fs.name,
                          detail: fs.name || "",
                          total: fs["total-bytes"],
                          used: fs["used-bytes"]
                      }))
            )
                .filter(item => item.total > 0)
                .sort((a, b) => String(a.label).localeCompare(String(b.label)));
            const used = rows
                .map(
                    row => row.values[host ? "storage_used" : "filesystem_used"]
                )
                .filter(v => v != null);
            // Less than a mebibyte either way is noise at this resolution.
            const delta = used.length < 2 ? null : used.at(-1) - used[0];
            // Describe storage growth or shrinkage over the selected period.
            const subject = host ? labels.allocated_space : labels.used_space;
            const when = periodText(data);
            change.textContent =
                delta == null
                    ? ""
                    : Math.abs(delta) < 1048576
                      ? text(labels.change_none, subject, when)
                      : text(
                            delta > 0 ? labels.change_up : labels.change_down,
                            subject,
                            bytes(Math.abs(delta)),
                            when
                        );
            change.classList.toggle(
                "cloudmin-statistics-change-up",
                delta != null && delta >= 1048576
            );
            // Explain absent storage readings instead of leaving an empty card.
            if (!list.length) {
                mounts.replaceChildren(
                    element(
                        "p",
                        "cloudmin-statistics-empty",
                        host ? labels.pools_empty : labels.filesystems_empty
                    )
                );
                return;
            }
            mounts.replaceChildren(
                ...list.map(item => {
                    const total = item.total;
                    // A missing reading is not zero usage. An overcommitted
                    // reading keeps its real figure, such as 120%; only the bar
                    // stops at full.
                    const usedBytes =
                        Number.isFinite(item.used) && item.used >= 0
                            ? item.used
                            : null;
                    const pct =
                        usedBytes == null ? null : (100 * usedBytes) / total;
                    const row = element("div", "cloudmin-statistics-mount");
                    // Nearly full filesystems take the warning and danger
                    // colors; the rest share the chart blue.
                    const bar = element(
                        "div",
                        "ui_progress_bar " +
                            (pct >= 90
                                ? "ui_bg_danger"
                                : pct >= 75
                                  ? "ui_bg_warning"
                                  : "cloudmin-statistics-mount-bar")
                    );
                    bar.style.width = Math.min(100, pct ?? 0).toFixed(1) + "%";
                    const track = element("div", "ui_progress_track");
                    track.append(bar);
                    row.append(
                        element(
                            "span",
                            "cloudmin-statistics-mount-path",
                            item.label
                        ),
                        element(
                            "span",
                            "cloudmin-statistics-mount-device",
                            item.detail
                        ),
                        track,
                        element(
                            "span",
                            "cloudmin-statistics-mount-usage",
                            text(
                                labels.mount_usage,
                                number(usedBytes, "bytes"),
                                bytes(total),
                                pct == null ? "–" : Math.round(pct)
                            )
                        )
                    );
                    return row;
                })
            );
        }

        // noticeText(data, rows, loading) prioritizes errors, gaps and the
        // recording status.
        function noticeText(data, rows, loading) {
            // Initial loading has no collection status to explain yet.
            if (loading) return ["", ""];
            // Explain disabled collection without reporting a failure.
            if (data.collector?.enabled === 0) return [labels.disabled, "info"];
            // An unavailable collector takes precedence over
            // history-gap notices.
            if (!data.collector?.available)
                return [labels.unavailable, "warning"];
            // Report a current collection error before interpreting older
            // history gaps.
            if (data.collector.error) return [data.collector.error, "warning"];
            const withDate = data.to - data.from > 86400;
            // Suppress gaps shorter than two ticks to avoid noisy
            // transient notices.
            const minimum = 2 * (data.collector.interval || 10);
            const collector = gaps(rows, "memory_allocated", minimum);
            const messages = [];
            // Summarize interior gaps in allocated-memory coverage as
            // collection gaps.
            if (collector.length)
                messages.push(
                    gapNotice(collector, labels.gap_collector, labels, withDate)
                );
            // Guest filesystem gaps may need a separate explanation from
            // collector gaps.
            if (!host) {
                // Agent gaps that coincide with collector gaps are
                // already reported.
                const agent = gaps(rows, "filesystem_total", minimum).filter(
                    ([a, b]) => !collector.some(([c, d]) => a < d && b > c)
                );
                // List agent-only gaps after excluding those already attributed
                // to collection.
                if (agent.length)
                    messages.push(
                        gapNotice(agent, labels.gap_agent, labels, withDate)
                    );
            }
            // Measured history gaps take precedence over the
            // recording-disabled reminder.
            if (messages.length)
                return [messages.join(" ") + " " + labels.gap_blank, "warning"];
            // Explain why the chart may rely on readings kept only in this
            // browser session.
            if (!data.recording) return [labels.recording_off, "info"];
            return ["", ""];
        }

        // draw(data, Plot, [loading]) renders every card from one API result.
        // Loading defaults to false. True draws empty axes before data arrives.
        function draw(data, Plot, loading = false) {
            // A theme can change its title bar or palette between refreshes.
            stickyLayout();
            const {shown, kind} = visibleGroups(data);
            let rows = data.series || [];
            if ((!data.recording || !data.history_available) && !kind) {
                // Recording off still shows live values from this
                // browser session.
                const t = data.collector?.checked_at;
                // Append each collector timestamp once even if the page
                // refreshes faster.
                if (t && t !== live.at(-1)?.t)
                    live.push({
                        t,
                        values: liveValues(data, host),
                        coverage: {},
                        peaks: {}
                    });
                while (live.length > 600) live.shift();
                const combined = new Map(rows.map(row => [row.t, row]));
                live.filter(
                    row => row.t >= data.from && row.t <= data.to
                ).forEach(row => combined.set(row.t, row));
                rows = [...combined.values()].sort((a, b) => a.t - b.t);
            }
            const current = liveValues(data, host);
            const [message, state] = noticeText(data, rows, loading);
            notice.textContent = message;
            notice.dataset.state = state;
            status.classList.toggle(
                "cloudmin-statistics-live",
                !loading && !!data.collector?.available
            );
            const checked = !loading && data.collector?.checked_at;
            // Show the sample interval and latest reading time, with a
            // countdown to the next refresh.
            if (checked) {
                sampling = data.resolution || data.collector.interval || 10;
                status.title = text(
                    labels.updated,
                    clock(data.collector.checked_at, false, true)
                );
                status.textContent = text(labels.samples, sampling);
            }
            // Without a checked timestamp, hide freshness details rather than
            // showing old ones.
            else {
                sampling = 0;
                countdown.hidden = true;
                status.removeAttribute("title");
                status.textContent = loading ? labels.loading : "";
            }
            shown.forEach(entry => {
                const group = entry.group;
                entry.data = data;
                entry.total =
                    group.total != null
                        ? Math.max(
                              0,
                              ...rows.map(
                                  row =>
                                      row.values[group.metrics[group.total]] ||
                                      0
                              ),
                              current.memory_allocated || 0
                          ) || null
                        : null;
                const available = rows.some(row =>
                    group.metrics.some(metric => row.values[metric] != null)
                );
                const values = [
                    rows.map(row => row.t),
                    ...group.metrics.map((metric, i) =>
                        rows.map(row => {
                            const value = row.values[metric];
                            // Nulls break plotted lines across
                            // missing measurements.
                            if (value == null || !Number.isFinite(value))
                                return null;
                            return group.mirrored && i === 1 ? -value : value;
                        })
                    )
                ];
                // Build a plot once, then retain its canvas and input handlers
                // across refreshes.
                if (!entry.chart) {
                    entry.chart = new Plot(
                        chartOptions(entry, Plot),
                        values,
                        entry.parent
                    );
                    bindZoom(entry);
                    resize.observe(entry.parent);
                } else {
                    // uPlot updates readings and scales without replacing
                    // the canvas.
                    entry.chart.setData(values);
                }
                entry.parent.classList.toggle(
                    "cloudmin-statistics-plot-empty",
                    !available && !loading
                );
                entry.parent.classList.toggle(
                    "cloudmin-statistics-plot-loading",
                    loading
                );
                entry.empty.textContent = loading
                    ? labels.loading
                    : kind
                      ? labels.no_device
                      : labels.empty;
                entry.empty.hidden = available;
                // Empty loading frames must not look like measured values.
                if (loading) {
                    entry.value.textContent = "–";
                    entry.detail.textContent = "";
                }
                // Loaded results may populate current values and
                // period summaries.
                else headline(entry, rows, current, kind);
            });
            // Storage bars require a real response rather than the initial
            // chart scaffold.
            if (!loading) drawMounts(data, rows);
            const list = data.events || [];
            // Add dates for custom ranges and periods of a day or more.
            const withDate =
                periodValue() === "custom" || data.to - data.from >= 86400;
            const nextEvents = JSON.stringify([withDate, list]);
            // Update the period label even when the events are unchanged.
            eventSummary.textContent = !list.length
                ? ""
                : list.length === 1
                  ? text(labels.event_count, periodText(data))
                  : text(labels.events_count, list.length, periodText(data));
            changes.hidden = !list.length;
            // Reuse unchanged rows to preserve the timeline's scroll position.
            if (nextEvents !== eventState) {
                // Keep API order (newest first) and render details as text.
                events.replaceChildren(
                    ...list.map(event => {
                        const item = element("li", "ui_feed_item");
                        const when = element(
                            "time",
                            "ui_feed_when",
                            clock(event.t, withDate)
                        );
                        when.dateTime = new Date(event.t * 1000).toISOString();
                        item.append(
                            when,
                            element("div", "ui_feed_text", event.detail)
                        );
                        return item;
                    })
                );
                eventState = nextEvents;
            }
        }

        // refresh() cancels superseded reads and never polls an invisible tab.
        async function refresh() {
            clearTimeout(timer);
            request?.abort();
            // A disposed panel cannot start requests after SPA navigation.
            if (destroyed) return;
            // Detached panels release observers, timers and charts immediately.
            if (!root.isConnected) {
                destroy();
                return;
            }
            // Choosing another period restores its full range, unlike a
            // live tick.
            if (period !== periodValue()) {
                period = periodValue();
                zoom = null;
            }
            // Invisible panels pause requests but schedule a later
            // visibility check.
            if (document.hidden || !active || !root.getClientRects().length) {
                timer = setTimeout(refresh, REFRESH);
                return;
            }
            const range = currentRange();
            // Keep invalid custom input local and wait for the user to apply
            // valid dates.
            if (!range) {
                notice.textContent = labels.custom_invalid;
                notice.dataset.state = "danger";
                return;
            }
            const controller = new AbortController();
            request = controller;
            // First load and recovery display loading status until a chart can
            // be drawn.
            if (!entries.some(entry => entry.chart)) {
                sampling = 0;
                countdown.hidden = true;
                status.textContent = labels.loading;
            }
            status.setAttribute("aria-busy", "true");
            const params = new URLSearchParams({
                action: "statistics",
                id: config.owner,
                from: range.from,
                to: range.to,
                points: 600
            });
            // Send a device identifier only for an explicit device view.
            if (device.value) params.set("entity", device.value);
            try {
                const [response, library] = await Promise.all([
                    fetch(config.api + "?" + params, {
                        signal: controller.signal,
                        credentials: "same-origin",
                        cache: "no-store",
                        headers: {
                            "Accept": "application/json",
                            "X-Requested-With": "XMLHttpRequest"
                        }
                    }),
                    assets(config).then(library => {
                        // Draw the axes first, using null values rather than
                        // fake zeroes.
                        if (
                            !entries.some(entry => entry.chart) &&
                            !device.value &&
                            !controller.signal.aborted &&
                            request === controller &&
                            root.isConnected
                        ) {
                            draw(
                                {
                                    from: range.from,
                                    to: range.to,
                                    recording: true,
                                    history_available: true,
                                    series: [range.from, range.to].map(t => ({
                                        t,
                                        values: {},
                                        coverage: {},
                                        peaks: {}
                                    }))
                                },
                                library,
                                true
                            );
                        }
                        return library;
                    })
                ]);
                // HTTP errors must clear the view instead of being treated as
                // chart data.
                if (!response.ok) throw new Error(labels.error);
                const body = await response.json();
                // A successful HTTP status can still contain an
                // API-level failure.
                if (body.error || !body.result)
                    throw new Error(body.error || labels.error);
                // Ignore responses overtaken by a newer request or
                // page navigation.
                if (request === controller && root.isConnected) {
                    // A shorter period can remove a device or make the filter
                    // redundant. Fetch totals before drawing the default view.
                    if (updateDevices(body.result.entities || [])) {
                        refresh();
                        return;
                    }
                    draw(body.result, library);
                }
            } catch (error) {
                // Superseded or hidden-panel requests must not replace the
                // active view with errors.
                if (error.name !== "AbortError" && request === controller) {
                    // A late asset load must not replace an API error
                    // with frames.
                    controller.abort();
                    // Clear stale or forbidden readings without shortening
                    // the page.
                    grid.style.minHeight = grid.offsetHeight + "px";
                    clear();
                    entries.forEach(entry => {
                        entry.card.hidden = false;
                        entry.empty.hidden = true;
                        entry.value.textContent = "–";
                        entry.detail.textContent = "";
                        if (entry.bar) entry.bar.style.width = "0";
                    });
                    // Hide previous storage readings after failure. Keep
                    // session samples for a later successful refresh.
                    mounts?.replaceChildren();
                    // Remove the old storage-change sentence along with
                    // its bars.
                    if (change) change.textContent = "";
                    // Clear the timeline and its summary after a failed read.
                    events.replaceChildren();
                    eventSummary.textContent = "";
                    changes.hidden = true;
                    eventState = undefined;
                    notice.textContent = labels.error + " " + error.message;
                    notice.dataset.state = "danger";
                    sampling = 0;
                    countdown.hidden = true;
                    status.textContent = "";
                    status.removeAttribute("title");
                    status.classList.remove("cloudmin-statistics-live");
                }
            } finally {
                // Only the active request may restart the refresh countdown
                // and timer.
                if (!destroyed && request === controller) {
                    status.removeAttribute("aria-busy");
                    timer = setTimeout(refresh, REFRESH);
                    startCountdown();
                }
            }
        }

        // onChange(event) handles the period and device controls. The custom
        // fields wait for Apply, so a half-edited moment is never requested.
        function onChange(event) {
            const name = event.target.name || "";
            // Period changes reveal custom inputs or restore a moving
            // preset window.
            if (name === "statistics_range") {
                const custom = event.target.value === "custom";
                customBox.hidden = !custom;
                // Initialize custom dates once so switching periods preserves
                // the user's choices.
                if (custom && !moment("statistics_from")[0].value) {
                    const now = Math.floor(Date.now() / 1000);
                    setMoment("statistics_from", now - 86400);
                    setMoment("statistics_to", now);
                }
                refresh();
            }
            // Device changes apply immediately without waiting for the
            // custom-range button.
            else if (name === "statistics_device") refresh();
        }

        // destroy() releases work when SPA navigation removes this panel.
        function destroy() {
            // Cleanup can be requested by both navigation and the next refresh.
            if (destroyed) return;
            destroyed = true;
            clearTimeout(timer);
            request?.abort();
            visibility.disconnect();
            // Stop palette callbacks once this panel is gone.
            paletteObserver.disconnect();
            colorScheme.removeEventListener("change", repaint);
            document.removeEventListener("visibilitychange", refresh);
            window.removeEventListener("resize", stickyLayout);
            root.removeEventListener("change", onChange);
            ["statistics_from", "statistics_to"].forEach(prefix =>
                themePicker()?.detach(moment(prefix)[0])
            );
            clear();
            delete root.dataset.statisticsMounted;
            delete root.cloudminStatisticsDispose;
        }
        root.cloudminStatisticsDispose = destroy;
        // Use the theme's calendar and clock, or keep the native fields.
        ["statistics_from", "statistics_to"].forEach(prefix => {
            const picker = themePicker();
            const [date, time] = moment(prefix);
            // Themes without the optional calendar keep native date and
            // time controls.
            if (!picker) return;
            date.type = "text";
            // Replace both native fields only after the theme
            // calendar initializes.
            if (
                picker.create(date, {
                    dateFormat: "yyyy-MM-dd",
                    timepicker: true,
                    timeFormat: "HH:mm",
                    minutesStep: 15,
                    autoClose: false,
                    readDate: () => momentDate(date.value)
                })
            ) {
                // The field now holds the time as well, so it needs the room.
                date.classList.add("cloudmin-statistics-moment");
                time.hidden = true;
            }
            // If calendar creation fails, restore the native date control.
            else date.type = "date";
        });
        // visibility(list) starts reads for visible panels and aborts
        // hidden-panel work.
        const visibility = new IntersectionObserver(list => {
            active = list.some(item => item.isIntersecting);
            // A newly visible panel refreshes immediately. A hidden one cancels
            // its read.
            if (active) refresh();
            else request?.abort();
        });
        visibility.observe(root);
        // Watch palette attributes without reacting to chart updates.
        for (let node = root; node; node = node.parentElement) {
            paletteObserver.observe(node, {
                attributes: true,
                attributeFilter: ["data-bgs", "data-ui-scheme"]
            });
        }
        // Follow the browser's light or dark preference in automatic mode.
        colorScheme.addEventListener("change", repaint);
        repaint();
        // A narrower window can wrap a theme title bar onto more lines.
        window.addEventListener("resize", stickyLayout);
        document.addEventListener("visibilitychange", refresh);
        root.addEventListener("change", onChange);
        root.querySelector(".cloudmin-statistics-apply")?.addEventListener(
            "click",
            event => {
                event.preventDefault();
                refresh();
            }
        );
    }

    // Mount new panels when SPA navigation reuses this script.
    if (!shared.observer) {
        shared.observer = new MutationObserver(records => {
            records.forEach(record => {
                record.removedNodes.forEach(node => {
                    // Ignore non-elements and nodes merely moved within the
                    // live document.
                    if (node.nodeType !== 1 || node.isConnected) return;
                    node.cloudminStatisticsDispose?.();
                    node.querySelectorAll(".cloudmin-statistics").forEach(
                        panel => panel.cloudminStatisticsDispose?.()
                    );
                });
                record.addedNodes.forEach(node => {
                    // Only attached element subtrees can contain new
                    // statistics panels.
                    if (node.nodeType !== 1 || !node.isConnected) return;
                    // The added node itself may be a panel rather than only
                    // containing one.
                    if (node.matches(".cloudmin-statistics")) mount(node);
                    node.querySelectorAll(".cloudmin-statistics").forEach(
                        mount
                    );
                });
            });
        });
        shared.observer.observe(document.body, {
            childList: true,
            subtree: true
        });
    }
    document.querySelectorAll(".cloudmin-statistics").forEach(mount);
})();
