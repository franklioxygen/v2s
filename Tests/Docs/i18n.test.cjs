const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const source = readFileSync(join(__dirname, "../../docs/js/i18n.js"), "utf8");

function createI18n(language, storedLang = null, languages = [language]) {
  const scripts = [];
  const storage = new Map([["v2s-home-lang", storedLang]]);
  const document = {
    documentElement: { dataset: {} },
    head: { appendChild: (script) => scripts.push(script) },
    createElement: () => ({}),
    querySelector: () => null,
    querySelectorAll: () => [],
    dispatchEvent: () => {},
  };
  const window = {};
  runInNewContext(source, {
    window,
    document,
    navigator: { language, languages },
    localStorage: {
      getItem: (key) => storage.get(key),
      setItem: (key, value) => storage.set(key, value),
    },
    CustomEvent: class {},
  });
  return { i18n: window.V2sI18n, document, scripts, window, storage };
}

test("selects English and Simplified Chinese dictionaries explicitly", () => {
  const { i18n, document, scripts } = createI18n("en-US");
  const englishTitle = i18n.t("meta.title");
  assert.equal(englishTitle, "v2s — Live bilingual subtitles for macOS");
  i18n.applyLang("zh");
  assert.equal(i18n.t("nav.download"), "下载");
  assert.equal(document.documentElement.lang, "zh-CN");
  assert.equal(document.title, i18n.t("meta.title"));
  i18n.applyLang("en");
  assert.equal(i18n.t("meta.title"), englishTitle);
  assert.equal(i18n.t("missing.translation"), "");
  assert.equal(scripts.length, 0);
});

test("honors valid stored language preferences", () => {
  assert.equal(createI18n("en-US", "zh").i18n.t("nav.download"), "下载");
  assert.equal(createI18n("zh-CN", "en").i18n.t("nav.download"), "Download");
});

test("honors the first Chinese locale preference", () => {
  const { document, i18n, scripts } = createI18n(
    "zh-CN",
    null,
    ["zh-CN", "zh-TW"],
  );
  assert.equal(scripts.length, 0);
  assert.equal(i18n.t("nav.download"), "下载");
  assert.equal(document.documentElement.lang, "zh-CN");
});

for (const language of ["zh", "zh-CN", "zh-SG", "zh-Hans", "zh-MY"]) {
  test(`keeps Simplified Chinese for ${language}`, () => {
    const { document, scripts } = createI18n(language);
    assert.equal(scripts.length, 0);
    assert.equal(document.documentElement.lang, "zh-CN");
  });
}

for (const language of ["__proto__", "constructor", "toString", "fr"]) {
  test(`does not select a dictionary for unsupported language ${language}`, () => {
    const { i18n, storage } = createI18n("zh-CN", language);
    assert.equal(i18n.getLang(), "zh");
    assert.equal(i18n.t("nav.download"), "下载");
    i18n.applyLang(language);
    assert.equal(i18n.getLang(), "en");
    assert.equal(i18n.t("nav.download"), "Download");
    assert.equal(storage.get("v2s-home-lang"), "en");
  });
}

for (const [language, variant, htmlLang] of [
  ["zh-TW", "twp", "zh-TW"],
  ["zh-Hant-TW", "twp", "zh-TW"],
  ["zh-HK", "hk", "zh-HK"],
  ["zh-MO", "hk", "zh-HK"],
]) {
  test(`preserves OpenCC conversion for ${language} and leaves English unchanged`, () => {
    const { i18n, document, scripts, window } = createI18n(language);
    assert.equal(scripts.length, 1);
    assert.equal(i18n.t("nav.download"), "下载");
    assert.equal(document.documentElement.lang, "zh-CN");
    window.OpenCC = {
      Converter: (options) => {
        assert.equal(options.from, "cn");
        assert.equal(options.to, variant);
        return (value) => `converted:${value}`;
      },
    };
    scripts[0].onload();
    assert.equal(i18n.t("nav.download"), "converted:下载");
    assert.equal(document.title, i18n.t("meta.title"));
    assert.equal(document.documentElement.lang, htmlLang);
    i18n.applyLang("en");
    assert.equal(i18n.t("nav.download"), "Download");
    i18n.applyLang("zh");
    assert.equal(i18n.t("nav.download"), "converted:下载");
  });
}

test("keeps Simplified Chinese when the converter cannot load or initialize", () => {
  const { i18n, document, scripts } = createI18n("zh-TW");
  assert.equal(document.documentElement.lang, "zh-CN");
  scripts[0].onerror();
  assert.equal(i18n.t("nav.download"), "下载");
  assert.equal(document.documentElement.lang, "zh-CN");
  scripts[0].onload();
  assert.equal(i18n.t("nav.download"), "下载");
  assert.equal(document.documentElement.lang, "zh-CN");
});
