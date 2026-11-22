# vendor/

Third-party source inlined into the generated report. Not a dependency of the
measurement — nothing here runs on the cluster or touches a number.

## chart.umd.js

[Chart.js](https://www.chartjs.org/) v4.4.0, MIT licensed, © Chart.js
Contributors. The UMD build as published, already minified upstream.

| | |
| --- | --- |
| Version | 4.4.0 |
| sha256 | `321e3a3fa98da4aaa957d10be57cbb514de0989eed8f9d726b5d05902cd01904` |
| Source | `chart.js-4.4.0.tgz` → `package/dist/chart.umd.js` |

`scripts/report.py` reads this file and inlines it at the `/*__CHARTJS__*/`
marker in `templates/report-template.html`, so `results/<scenario>-report.html`
is a single file with no network dependency. It was a CDN `<script src>` before;
the failure that motivated vendoring is quiet rather than loud — offline, the
page still renders and the tables are still right, only the canvases are blank,
which reads as a run that collected nothing.

### Updating

```bash
curl -fsSL https://registry.npmjs.org/chart.js/-/chart.js-<version>.tgz \
  | tar -xzO package/dist/chart.umd.js > vendor/chart.umd.js
shasum -a 256 vendor/chart.umd.js     # record it in the table above
```

Take it from the npm registry, not a CDN: jsdelivr prepends a banner, so its
copy does not match the published hash even when the body is identical.

`report.py` refuses to inline a build containing a literal `</script`, which
would close the page's script block early. 4.4.0 has none.
