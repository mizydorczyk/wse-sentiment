# Plan: sentiment.R + clustering.R + raport HTML (wariant A — leksykonowy R-native)

## Context

Projekt `wse-sentiment` (PSI 2026, deadline 07.06.2026). Pipeline zbierania danych już działa: RSS + archive → scrape → parse → `assign_tickers.R` (5 testowych artykułów, docelowo ~2000). Brak analizy treści.

Wymagania zaliczeniowe Cz. I (25 pkt): R + dane + raport HTML, min. 2 techniki z listy.

Cel: skrypty `src/sentiment.R` + `src/clustering.R` + `report/raport.Rmd` source'ujący wyniki, 100% R-native, 4 techniki:
1. **Sentyment leksykonowy** — plWordNet emo + custom finansowy PL + lematyzacja udpipe
2. **LDA topic modeling** — automatyczna klasyfikacja artykułów na tematy
3. **TF-IDF per ticker** — semantyczne profile spółek
4. **Częstość słów + wordcloud** — overview globalny i per topic

Zero Python, zero reticulate, zero API calls — pełna replikowalność, zgodność z deklaracją "R + dane".

---

## Część 1: Słowniki — co pobrać i jak

**Stack 3 słowników (union, z hierarchią overriding):**
1. **LM_PL_custom** (~30 słów) — polskie specyfiki: hossa, bessa, parkiet, KNF, NBP, WIBOR, frankowiczów, dywidenda... Override dla wszystkiego.
2. **LM_PL_translated** (~4150 słów) — Loughran-McDonald przetłumaczony z EN na PL przez DeepL Free API + lemma walidacja udpipe + manual review TOP 200 najczęstszych w korpusie bankier.pl
3. **plWordNet emo** (~31k słów) — najszerszy fallback, pokrywa ogólny PL kiedy LM nie ma dopasowania

Priorytet na konfliktach: `LM_PL_custom > LM_PL_translated > plWordNet`. Razem ~35k słów pokrycia.

### 1A. plWordNet 4.5 emo (Słowosieć)

**URL pobierania:**
- Strona zasobu: https://clarin-pl.eu/dspace/handle/11321/834
- Direct download: na stronie kliknąć "Pliki" → `plwordnet_4_5.zip` (~444MB)
- Wymagana akceptacja licencji (free, też komercyjne; bez rejestracji)
- Alternatywa techniczna: API CLARIN-PL https://clarin-pl.eu/dspace/rest/bitstream/

**Co zawiera:**
- ~287k jednostek leksykalnych (lemma + POS)
- ~31k jednostek z anotacją polaryzacji: `strong_positive`, `weak_positive`, `neutral`, `weak_negative`, `strong_negative`, `ambiguous`
- 8 emocji Plutchika (anger, anticipation, disgust, fear, joy, sadness, surprise, trust)
- Format: XML (struktura: `<lexicalUnit>` z atrybutami lemma, pos, sentiment, emotions)

**Jak parsować w R:**
- Skrypt `src/build_plwordnet_csv.R` (one-shot, nie source'owany przez resztę)
- Używa `xml2::read_xml()` + `xml_find_all()` + `xml_attr()`
- Output: `dataset/dictionaries/plwordnet_emo.csv` (~31k wierszy, ~2MB)
- Format CSV:
  ```csv
  lemma,pos,sentiment,emotions
  zysk,noun,strong_positive,"joy;trust"
  strata,noun,strong_negative,"sadness;fear"
  ```
- Mapowanie sentymentu do binary: `strong_positive`+`weak_positive` → `positive`, `strong_negative`+`weak_negative` → `negative`, reszta odrzucona.

**Decyzja: czy commitować plWordNet CSV (~2MB) do repo?**
- TAK — zapewnia że `Rscript src/sentiment.R` działa od razu po `git clone` (bez pobierania 444MB ZIP-a)
- Skrypt `build_plwordnet_csv.R` zostaje w repo jako dokumentacja procesu
- Oryginalny XML zip NIE commitujemy (.gitignore)

### 1B. Loughran-McDonald przetłumaczony na PL

**Źródło EN:** `~/repo/Projektowanie_systemow_informatycznych_2026/04.Zajecia/_Slowniki_w_CSV/loughran.csv` (~4150 wierszy: word, sentiment)

**Tłumacz: DeepL Free API**
- Rejestracja: https://www.deepl.com/pro-api?cta=header-pro-api (Free plan)
- API key z suffixem `:fx` (Free) — znajdziesz w panelu "Account" → "Authentication Keys"
- Free tier: 500k znaków/miesiąc (4150 słów ≈ 35-50k znaków = mieści się z dużym zapasem)
- W R przez pakiet `deeplr` (CRAN): `deeplr::translate2(text, target_lang = "PL", auth_key = Sys.getenv("DEEPL_API_KEY"))`
- API key trzymamy w `~/.Renviron` jako `DEEPL_API_KEY=xxx:fx` (nie commitujemy)

**Pipeline (one-shot skrypt `src/build_lm_pl.R`):**
1. Load `loughran.csv` (~4150 word, sentiment)
2. Per word: `deeplr::translate2(word, "PL", "EN", auth_key)` — z `Sys.sleep(0.1)` żeby nie hit rate limit
3. Cache wyników do `dataset/dictionaries/_cache/lm_translations_raw.csv` (na wypadek przerwania można wznowić)
4. Walidacja lemma: `udpipe::udpipe_annotate(udpipe_model, x)` na każdym tłumaczeniu → wyciągamy lemma głównego tokenu (jeśli fraza wielowyrazowa, bierzemy NOUN; jeśli czasownik bezokolicznik)
5. Deduplikacja: różne EN słowa → ten sam PL lemma (np. "loss"/"deficit"/"shortfall" → "strata"). Merge: bierzemy najsilniejszy sentiment per kategoria, w `source` zapisujemy listę EN źródeł
6. Output: `dataset/dictionaries/sentiment_lm_pl.csv`

**Format `sentiment_lm_pl.csv`:**
```csv
lemma,pos,sentiment,category,source_en,verified
zysk,NOUN,positive,positive,"profit;gain;earnings",manual
strata,NOUN,negative,negative,"loss;deficit;shortfall",manual
niepewność,NOUN,negative,uncertainty,"uncertainty;volatile",auto
pozew,NOUN,negative,litigious,"lawsuit;litigation",manual
regulacja,NOUN,negative,constraining,"regulation;restriction",auto
```

Kategorie zgodne z LM 2011: `positive`, `negative`, `uncertainty`, `litigious`, `constraining`. Pomijamy `modal_strong/weak` i `superfluous` (małe znaczenie dla raportu).

**Manual review TOP 200 najczęstszych:**
1. Po wygenerowaniu `sentiment_lm_pl.csv`: liczymy frequency lematów w korpusie (5 testowych + tytuły z `feeds.csv` na razie, później na 2k artykułach)
2. Top 200 najczęściej występujących PL lematów które są w słowniku → ręczna weryfikacja
3. Dla każdego: czy tłumaczenie + kategoria są OK w kontekście finansowym? (np. EN "expose" → PL "ekspozycja" w finansach OK, ale "wystawa" nie)
4. Flagujemy `verified = manual` lub `verified = auto` (reszta = auto)
5. Czas: ~2h

### 1C. Custom PL specifik (mini)

**Plik:** `dataset/dictionaries/sentiment_pl_custom.csv`

Słownik czego NIE MA w EN Loughran-McDonald (bo to PL/GPW-specific):
```csv
lemma,pos,sentiment,category,notes
hossa,NOUN,positive,positive,gielda
bessa,NOUN,negative,negative,gielda
parkiet,NOUN,neutral,neutral,gielda
rajd,NOUN,positive,positive,gielda
przecena,NOUN,negative,negative,gielda
korekta,NOUN,negative,negative,gielda
odbicie,NOUN,positive,positive,gielda
frankowiczów,NOUN,negative,litigious,prawne
KNF,PROPN,neutral,constraining,regulator
NBP,PROPN,neutral,neutral,regulator
WIBOR,PROPN,neutral,neutral,wskaznik
awaria,NOUN,negative,negative,
...
```

~30 wierszy. Robione ręcznie (15 min). Override względem LM_PL_translated.

### 1D. Stopwordsy PL

**Źródło:** pakiet R `stopwords` — `stopwords::stopwords("pl", source = "stopwords-iso")`
- ~342 słowa
- Nie wymaga osobnego pobierania, jest w pakiecie
- Plus: dorzucimy ~20 domain-specific stopwordów ("artykuł", "ten", "ostatni", "kwartał" itd.) jako `dataset/dictionaries/stopwords_custom_pl.csv`

### 1E. Model udpipe PL (już mamy)

`assets/udpipe/polish-pdb-ud-2.5-191206.udpipe` — używany przez `assign_tickers.R`. Weryfikujemy że plik istnieje, jeśli nie — pobieramy:
```r
udpipe::udpipe_download_model(language = "polish-pdb", model_dir = "assets/udpipe/")
```

---

## Część 2: Proces budowy stack'u słowników — krok po kroku

### Etap A: plWordNet emo (one-shot, ~1.5h)

**Format wejściowy: MySQL SQL dump 2.6GB (user pobrał `wordnet_work_4_5.zip` z CLARIN-PL).**

Struktura SQL: tabele `lexicalunit` (id, lemma, pos:int, ...) i `emotion` (lexicalunit_id, markedness:varchar(5), ...). Markedness wartości: `+ s` (strong positive), `+ m` (weak positive), `- s` (strong negative), `- m` (weak negative), `amb` (ambiguous), `0`/`` (neutral).

POS w plWN to int → mapping na UD POS (potwierdzić podczas implementacji):
- 1 → NOUN
- 2 → VERB
- 3 → ADJ
- 4 → ADV

**Parser: R-native (decyzja użytkownika — zero zewnętrznych downloadów):**

1. **Setup workspace** (~5 min):
   - User ustawia `WSE_WORKSPACE=~/wse_workspace/wse-sentiment` w `~/.Renviron` (lub używa default)
   - Kopiuje/przenosi `wordnet_work_4_5.zip` do `$WSE_WORKSPACE/raw/`

2. **`src/build_plwordnet_csv.R`** (~1h implementacji):
   - Krok 1: `system2("unzip", c("-p", zip_path, "wordnet_work_4_5.sql"), stdout = pipe_to_awk)` — extract na bieżąco
   - Krok 2: awk pre-process — wyciąga tylko `INSERT INTO lexicalunit/emotion` linie + splituje tuple po `),(` (na nowe linie)
   - Krok 3: streaming read w R przez `readr::read_lines_chunked()` (chunk 100k linii)
   - Krok 4: per tupla `INSERT INTO lexicalunit`: regex `^\((\d+),'([^']*)',(\d+),(\d+),` → wyciąga id, lemma, domain, pos (pierwsze 4 pola, ignoruje resztę)
   - Krok 5: per tupla `INSERT INTO emotion`: regex `^\((\d+),(\d+),'([^']*)','([^']*)','([^']*)',` → wyciąga id, lex_id, emotions, valuations, markedness (pierwsze 5 pól)
   - Krok 6: `dplyr::inner_join(lex, emo, by = c("id" = "lexicalunit_id"))`
   - Krok 7: map markedness → sentiment (`+ s`/`+ m` → "positive", `- s`/`- m` → "negative", `amb`/`""`/`0` → drop)
   - Krok 8: map pos int → UD POS string
   - Krok 9: `write.csv()` do `dataset/dictionaries/plwordnet_emo.csv`
   - Akceptacja drop ~2-3% wpisów na edge cases (apostrofy w lemach typu "O'Reilly") — log + raportowanie liczby pominięć

3. **Wynikowy CSV `plwordnet_emo.csv`:**
   ```csv
   lemma,pos,sentiment,markedness
   zysk,NOUN,positive,"+ s"
   strata,NOUN,negative,"- s"
   wątpliwy,ADJ,negative,"- m"
   ```
   ~31k wierszy, ~2MB. Edge cases (~3% drop) zalogowane.

### Etap B: Loughran-McDonald PL (one-shot, ~3-4h)

1. **DeepL setup** (~10 min):
   - Rejestracja konta DeepL Free na https://www.deepl.com/pro-api
   - Pobranie API key z panelu (suffix `:fx`)
   - `echo 'DEEPL_API_KEY=xxx:fx' >> ~/.Renviron` + restart R
   - `install.packages("deeplr")`
   - Test: `deeplr::translate2("profit", "PL", "EN", Sys.getenv("DEEPL_API_KEY"))` → "zysk"

2. **`src/build_lm_pl.R`** (~1h implementacja):
   - Load `loughran.csv` (~4150 EN + sentiment + category)
   - Per row: translate EN → PL (z `Sys.sleep(0.05)` rate-limit, batching po 50)
   - Cache do `dataset/dictionaries/_cache/lm_translations_raw.csv` (CHECKPOINT: skrypt umie wznowić od ostatniego cached row jeśli się wywróci)
   - Per PL translation: udpipe → wyciągnij lemma (główny NOUN jeśli fraza, lub VERB infinitive)
   - Dedupe per (lemma, sentiment, category): merge EN źródeł do `source_en` (separator `;`)
   - Save `sentiment_lm_pl.csv` z kolumną `verified = "auto"` dla wszystkich

3. **Uruchomienie** (~30-60 min wall clock, w tle):
   - `Rscript src/build_lm_pl.R`
   - 4150 requestów × ~0.5s = ~35 min
   - Cache zabezpiecza przed rate-limit / network issue

4. **Frequency analysis w korpusie** (~15 min):
   - Skrypt `src/build_lm_pl_topfreq.R`:
   - Load wszystkie obecne artykuły (5) + tytuły z `feeds.csv`
   - Lemmatyzuj → count frequency per lemma
   - Inner join z `sentiment_lm_pl.csv` (lemma)
   - Sortuj desc po freq
   - Output: `dataset/dictionaries/_review/lm_pl_top200.csv` (top 200 lematów do ręcznej weryfikacji)

5. **Manual review TOP 200** (~2h):
   - Otwórz CSV w edytorze
   - Dla każdego wiersza: czy tłumaczenie + kategoria są OK w kontekście finansowym?
   - Edytuj `lemma` / `sentiment` / `category` jeśli źle
   - Zmień `verified` na `manual`
   - Save → uruchamiamy merge skrypt (`src/apply_lm_pl_review.R`) który aktualizuje `sentiment_lm_pl.csv` o poprawione wpisy

### Etap C: Custom PL specifik (~15 min)

1. Ręcznie spisz `dataset/dictionaries/sentiment_pl_custom.csv` (~30 wierszy)
2. Słowa: hossa, bessa, parkiet, rajd, przecena, korekta, odbicie, frankowiczów, KNF, NBP, WIBOR, WIG, awaria, dywidenda, lokata, kredyt_hipoteczny, lichwa, ...
3. `verified = manual` dla wszystkich
4. Commit

### Etap D: Sanity test (~30 min)

`tests/testthat/test_sentiment_sanity.R`:
- Liczy sentyment dla każdego z 5 obecnych artykułów używając UNION wszystkich 3 słowników
- Oczekiwane:
  - `ALR` (awaria) → score < 0
  - `ING premia` → score > 0
  - `ranking Złoty Bankier` → score > 0
  - `mBank Złoty Bankier` → score > 0
  - `Saxo Bank` (info) → score ~ 0 (tolerance |score| < 2)
- Jeśli któryś nie pasuje → debug: print top words pos/neg które wpadły do score, znajdź problematyczne tłumaczenia, dodaj do `sentiment_pl_custom.csv` jako override

### Etap E: Final integration

`load_sentiment_lexicon()` w `src/sentiment.R`:
```r
load_sentiment_lexicon <- function() {
  plwn <- read.csv(constants$sentiment_lexicon_general) |>
    select(lemma, pos, sentiment) |>
    mutate(source = "plwn", priority = 1)
  lm_pl <- read.csv(constants$sentiment_lm_pl) |>
    select(lemma, pos, sentiment, category) |>
    mutate(source = "lm_pl", priority = 2)
  pl_custom <- read.csv(constants$sentiment_pl_custom) |>
    select(lemma, pos, sentiment, category) |>
    mutate(source = "pl_custom", priority = 3)

  bind_rows(plwn, lm_pl, pl_custom) |>
    group_by(lemma, pos) |>
    slice_max(priority, n = 1, with_ties = FALSE) |>  # higher priority wins
    ungroup()
}
```

**Łączny czas budowy stack'u słowników: ~5-6h** (z tego ~30-60 min wall time DeepL w tle)

---

## Część 3: Plan działania (sekwencja kroków implementacyjnych)

### Etap 1: Setup środowiska (~30 min)
1. `install.packages(c("tm", "tidytext", "topicmodels", "cluster", "factoextra", "wordcloud", "RColorBrewer", "ggrepel", "ggthemes", "knitr", "rmarkdown", "DT", "SnowballC", "stopwords", "scales", "lubridate", "deeplr", "xml2"))`
2. `renv::snapshot()`
3. Weryfikacja: `assets/udpipe/polish-pdb-ud-2.5-191206.udpipe` istnieje (jeśli nie → download)
4. Setup DeepL: rejestracja konta Free → API key do `~/.Renviron` jako `DEEPL_API_KEY=xxx:fx`
5. Dodać do `src/common/constants.R` nowe ścieżki (listed below)

### Etap 2: Słowniki (~5-6h, większość offline w tle)
6. plWordNet: download ZIP z CLARIN-PL, `src/build_plwordnet_csv.R`, generuj `plwordnet_emo.csv`
7. LM_PL: `src/build_lm_pl.R` (DeepL → udpipe lemma → dedupe), generuj `sentiment_lm_pl.csv`
8. LM_PL review: `src/build_lm_pl_topfreq.R` → manual review TOP 200 → `src/apply_lm_pl_review.R`
9. `dataset/dictionaries/sentiment_pl_custom.csv` (~30 wierszy, ręcznie)
10. `dataset/dictionaries/stopwords_custom_pl.csv` (~20 słów)
11. Commit słowniki (plWN CSV + LM_PL CSV + custom CSV; NIE commitujemy oryginalnego plWN ZIP ani cache DeepL)

### Etap 3: Shared text pipeline (~1h)
12. `src/common/text_pipeline.R` — funkcje reuse:
    - `load_articles_with_tickers()` — manifest + JSON → tibble (article_id, ticker, publication_date, text)
    - `clean_text(x)` — normalizacja apostrofów, lower, usunięcie cyfr i interpunkcji
    - `lemmatize_tokens(text_vec, model)` — udpipe lemma tokens
    - `load_stopwords_pl()` — stopwords + custom
    - `load_sentiment_lexicon()` — union 3 słowników z priorytetem

### Etap 4: `src/sentiment.R` (~2h)
13. Implementacja zgodnie ze szkicem (Część 4 poniżej)
14. `tests/testthat/test_sentiment.R` (smoke test + sanity test na fixturach)
15. Sanity: weryfikacja że ALR < 0, ING > 0 itp.

### Etap 5: `src/clustering.R` (~2h)
16. Implementacja LDA + TF-IDF + word frequency
17. `tests/testthat/test_clustering.R`

### Etap 6: Raport `report/raport.Rmd` (~2h)
18. Struktura 7 sekcji (Wprowadzenie, Dane, Częstość, Sentyment ×3, LDA, TF-IDF, Wnioski)
19. Wszystkie chunki ładują CSV-ki z `dataset/processed/` i PNG z `assets/figures/`
20. Render: `Rscript -e 'rmarkdown::render("report/raport.Rmd")'`

### Etap 7: Polish & commit (~30 min)
21. Lintr/styler pass na nowych plikach
22. Pre-commit hook check
23. Commit + push do `fzablocki`

**Łączny czas: ~13-15h** (z czego ~1h to wall time DeepL/parsowania, leci w tle)

---

## Część 4: Struktura plików

### `src/common/constants.R` — nowe ścieżki

```r
constants$sentiment_lexicon_general <- "dataset/dictionaries/plwordnet_emo.csv"
constants$sentiment_lm_pl <- "dataset/dictionaries/sentiment_lm_pl.csv"
constants$sentiment_pl_custom <- "dataset/dictionaries/sentiment_pl_custom.csv"
constants$stopwords_custom <- "dataset/dictionaries/stopwords_custom_pl.csv"
constants$sentiment_per_article <- "dataset/processed/sentiment_per_article.csv"
constants$sentiment_per_ticker <- "dataset/processed/sentiment_per_ticker.csv"
constants$sentiment_timeline <- "dataset/processed/sentiment_timeline.csv"
constants$topics_lda <- "dataset/processed/topics_lda.csv"
constants$article_topic_gamma <- "dataset/processed/article_topic_gamma.csv"
constants$tfidf_per_ticker <- "dataset/processed/tfidf_per_ticker.csv"
constants$word_freq <- "dataset/processed/word_freq.csv"
constants$figures_dir <- "assets/figures"
constants$udpipe_model_pl <- "assets/udpipe/polish-pdb-ud-2.5-191206.udpipe"

# Sentiment computation params (configurable)
constants$sentiment_ticker_min_relevance <- 5  # próg dla per-ticker; 0=wszystkie z manifest
constants$sentiment_negation_window <- 3       # ile tokenów przed sprawdzamy negator
constants$sentiment_lda_k <- 5                 # LDA topic count (2-3 dla testu, 5-10 dla produkcji)
constants$sentiment_timeline_granularity <- "week"  # week | day | month
```

### `src/sentiment.R` (struktura)

```r
#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(tidyr); library(stringr)
  library(tidytext); library(udpipe); library(stopwords)
  library(ggplot2); library(wordcloud); library(RColorBrewer); library(lubridate)
})
source("src/common/constants.R")
source("src/common/text_pipeline.R")

# Funkcje:
# - load_sentiment_lexicon() -> tibble(lemma, sentiment, category)
#   union plWN + financial; financial bije plWN na konflikcie lematy
# - compute_sentiment(tokens, lexicon) -> tibble(article_id, sentiment, category, n)
# - summarize_per_article(s) -> article_id, score, n_pos, n_neg, n_uncertainty, top_pos_words, top_neg_words
# - summarize_per_ticker(s, articles) -> ticker, mean_score, n_articles, articles_pos, articles_neg
# - summarize_timeline(s, articles, by="week") -> period, mean_score, n_articles
# - plot_* (bar per ticker, wordcloud pos/neg, timeline)
# - save_outputs(...)

# Main flow:
# articles <- load_articles_with_tickers()
# tokens <- lemmatize_tokens(articles, udpipe_model)
# lexicon <- load_sentiment_lexicon()
# sent <- compute_sentiment(tokens, lexicon)
# save 3 CSV + 4 PNG
```

### `src/clustering.R` (struktura)

```r
#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(tidyr); library(stringr)
  library(tm); library(tidytext); library(topicmodels); library(udpipe)
  library(stopwords); library(ggplot2); library(wordcloud); library(RColorBrewer)
})
source("src/common/constants.R")
source("src/common/text_pipeline.R")

# Funkcje:
# - build_dtm(tokens_df, sparse=0.99) -> DocumentTermMatrix
# - run_lda(dtm, k=5, seed=1234) -> LDA object
# - extract_topics_beta(lda) -> topic, word, beta
# - extract_article_gamma(lda) -> article_id, topic, gamma
# - compute_tfidf_per_ticker(tokens, articles) -> ticker, word, tf, idf, tf_idf
# - compute_word_freq(tokens) -> word, freq
# - plot_topics_facet, plot_tfidf_facet, plot_wordcloud_global, plot_wordcloud_per_topic
```

### `report/raport.Rmd` (struktura)

7 sekcji:
1. Wprowadzenie (cel, dane, metodologia)
2. Dane i preprocessing (pipeline, słowniki, lematyzacja)
3. Częstość słów (top 30 + global wordcloud)
4. Sentyment
   - 4a. Top słowa pos/neg (bar) + wordcloud pos/neg
   - 4b. Ranking spółek (bar mean_score per ticker)
   - 4c. Indeks GPW w czasie (geom_line + geom_smooth weekly)
5. Topic modeling LDA (top 10 słów per topic + heatmap article × topic + wordcloud per topic)
6. Profile semantyczne (TF-IDF top 10 słów per top 10 tickerów, facet)
7. Wnioski (top 3 pos/neg spółki, główne tematy)

YAML header z `theme: readable`, `code_folding: hide`, `toc_float: true`.

---

## Część 5: Krytyczne pliki

**Nowe:**
- `src/sentiment.R`
- `src/clustering.R`
- `src/common/text_pipeline.R`
- `src/build_plwordnet_csv.R` (one-shot, parser XML)
- `src/build_lm_pl.R` (one-shot, DeepL translation)
- `src/build_lm_pl_topfreq.R` (one-shot, frequency analysis dla review)
- `src/apply_lm_pl_review.R` (one-shot, merge manual edits)
- `dataset/dictionaries/plwordnet_emo.csv` (~31k wierszy, generowany)
- `dataset/dictionaries/sentiment_lm_pl.csv` (~4150 wierszy, generowany przez DeepL + manual review TOP 200)
- `dataset/dictionaries/sentiment_pl_custom.csv` (~30 wierszy, ręczny)
- `dataset/dictionaries/stopwords_custom_pl.csv` (~20 wierszy, ręczny)
- `report/raport.Rmd`
- `tests/testthat/test_sentiment.R`
- `tests/testthat/test_clustering.R`

**Modyfikowane:**
- `src/common/constants.R` (nowe ścieżki)
- `renv.lock` (po `renv::snapshot()`)
- `.gitignore` (ignorować pobrany `plwordnet_4_5.zip`, `dataset/dictionaries/_cache/`, `dataset/dictionaries/_review/`)

## Część 6: Reuse z istniejącego kodu

- `src/assign_tickers.R` — wzorzec stylu, użycie `udpipe`, `processed_manifest`, struktura output (json + CSV)
- `src/parse_article.R` — pola JSON (`content$lead`, `content$paragraphs`, `metadata$publication_date`)
- `src/common/constants.R` — wzorzec istniejących stałych

## Część 7: Verification

1. `Rscript src/build_plwordnet_csv.R` (one-shot po pobraniu ZIP) → `dataset/dictionaries/plwordnet_emo.csv` exists, >20k wierszy
2. `Rscript src/sentiment.R` → 3 CSV w `dataset/processed/` + 4 PNG w `assets/figures/`
3. `Rscript src/clustering.R` → 4 CSV + 6+ PNG
4. `Rscript -e 'rmarkdown::render("report/raport.Rmd")'` → `report/raport.html`, 7 sekcji, wszystkie wizualizacje
5. `Rscript -e 'testthat::test_dir("tests/testthat", reporter="progress", chdir = TRUE)'` → wszystko zielone
6. **Sanity na 5 testowych artykułach:**
   - `ALR` (awaria): score < 0
   - `ING premia`: score > 0
   - `Złoty Bankier` (mBank): score > 0
   - `Saxo Bank` (info): score ~ 0
7. Pre-commit hook (styler + lintr) na nowych plikach: bez warningów

## Część 8: Paralelizacja i sesje pracy

### Co jest niezależne od pobierania słowników (do zrobienia TERAZ)

| Komponent | Zależności | Status bez słowników |
|-----------|-----------|---------------------|
| Setup renv | brak | ✓ DZIAŁA |
| `src/common/text_pipeline.R` | udpipe (mamy), stopwords (CRAN) | ✓ DZIAŁA |
| `src/clustering.R` (LDA + TF-IDF + freq + wordcloud) | text_pipeline | ✓ **W PEŁNI DZIAŁA** — nie używa sentymentu |
| `src/sentiment.R` szkielet | text_pipeline + mini PL custom (30 słów) | ◐ DZIAŁA z ubogimi wynikami |
| `src/build_plwordnet_csv.R` (kod) | xml2 | ✓ kod gotowy, run wymaga ZIP |
| `src/build_lm_pl.R` (kod) | deeplr | ✓ kod gotowy, run wymaga API key |
| `report/raport.Rmd` scaffold | rmarkdown | ✓ struktura gotowa, sekcje w tryCatch |

### Sesja 1: Foundation + clustering full (~3-4h)

**Sequential start (1h):**
1. Agent A — Setup renv (install pakietów + snapshot) + extension `src/common/constants.R`
2. Agent A — `src/common/text_pipeline.R`

**Parallel batch (~2h, 3 agenci równolegle):**
3. Agent B — `src/clustering.R` + `tests/testthat/test_clustering.R`. Pełny LDA + TF-IDF + freq + wordcloud. Działa end-to-end na 5 artykułach.
4. Agent C — `src/build_plwordnet_csv.R` + `src/build_lm_pl.R` (kod + dry-run na 10 słowach jeśli DeepL key dostępny)
5. Agent D — `report/raport.Rmd` scaffold (7 sekcji z YAML + placeholder chunki w tryCatch) + `dataset/dictionaries/sentiment_pl_custom.csv` (~30 wierszy ręcznie) + `dataset/dictionaries/stopwords_custom_pl.csv`

**Final sequential (~30 min):**
6. Agent E — `src/sentiment.R` szkielet używający tylko PL custom + sanity test

**Po Sesji 1:**
- Działający clustering na 5 artykułach (3 techniki, raport potrafi to pokazać)
- Sentiment pipeline z ubogim słownikiem (proof of concept)
- Wszystkie skrypty słownikowe gotowe do uruchomienia
- Repo lintowane, commit-ready

### Między sesjami (user, ~30-45 min)
- Rejestracja DeepL Free → API key → `~/.Renviron`
- Download plWN 4.5 ZIP z CLARIN-PL (akceptacja licencji)

### Sesja 2: Słowniki (~2-3h, w tym ~35 min wall time DeepL)

**Parallel (2 agenci):**
1. Agent A — Uruchom `Rscript src/build_plwordnet_csv.R` → generuje `plwordnet_emo.csv` (~31k wierszy)
2. Agent B — Uruchom `Rscript src/build_lm_pl.R` → DeepL translation 4150 słów (~35 min wall) → `sentiment_lm_pl.csv`

**Sequential po wynikach (~1h):**
3. Agent C — `src/sentiment.R` rozszerzenie: `load_sentiment_lexicon()` union 3 źródeł z priorytetem
4. Agent C — Uruchom `src/build_lm_pl_topfreq.R` → generuje `_review/lm_pl_top200.csv`
5. Sanity test: sentyment na 5 artykułach — debug jeśli ALR/ING nie zachowują się jak oczekiwano

### Między sesjami (user, ~2h)
- Manual review `lm_pl_top200.csv` (otworz w edytorze, popraw tłumaczenia/kategorie, flaguj `verified=manual`)

### Sesja 3: Integration + raport (~1-2h)
1. Agent A — `src/apply_lm_pl_review.R` merge → final `sentiment_lm_pl.csv`
2. Agent B — Uruchom `src/sentiment.R` na pełnych słownikach → finalne CSV/PNG
3. Agent C — Wypełnienie raport.Rmd ze wskazaniami na rzeczywiste CSV/PNG → render → `report/raport.html`
4. Lint + styler + pre-commit check + commit + push

**Łączny czas modelu: ~6-8h** rozłożone na 3 sesje. **Twoja praca: ~3h** (DeepL setup + plWN download + manual review).

### Reguły paralelizacji (żeby uniknąć kolizji)

- Każdy agent dostaje WŁASNY plik(i) do pisania. `src/common/constants.R` modyfikuje WYŁĄCZNIE Agent A w Sesji 1 (jeden raz, dodaje wszystkie ścieżki naraz).
- Agenci czytają z istniejących plików (CONTEXT.md, repo) i piszą do swoich. Brak współdzielonego pisania.
- Jeśli paralel agenci muszą edytować ten sam plik (np. constants.R) → dispatch SEKWENCYJNIE.
- Worktree NIE jest potrzebny przy tej dyscyplinie (każdy plik ma 1 writera per sesja).

## Część 9: Zaadresowane decyzje techniczne

### 9.1 POS matching: (lemma, UD POS) z mapowaniem plWN → UD

- Join słownik ↔ tokeny po `(lemma, ud_pos)` gdzie `ud_pos ∈ {NOUN, VERB, ADJ, ADV}`
- plWordNet używa własnych POS tagów (`noun`, `verb`, `adj`, `adv`) → mapping w `src/build_plwordnet_csv.R` (~5 linii)
- LM_PL po DeepL + udpipe lemma już ma UD POS natywnie
- PL_custom — POS dopisujemy ręcznie podczas tworzenia CSV
- Eliminuje cross-POS false positives ("długi" ADJ vs "dług" NOUN)
- Brak fallbacku na lemma-only (nie psujemy precyzji recall'em)

### 9.2 Negacja: heurystyka window 3-tokeny PRZED

- Lista negatorów PL: `nie`, `bez`, `brak`, `żaden`, `żadna`, `żadne`, `nigdy`, `ani`, `ni`
- Algorytm: dla każdego tokenu z sentymentem → sprawdź 3 poprzedzające tokeny w tym samym zdaniu → jeśli któryś jest negatorem → flip polaryzacji (positive ↔ negative; uncertainty/litigious/constraining bez zmiany)
- Implementacja: ~10-15 linii w `compute_sentiment()` (`src/sentiment.R`)
- Stosowane tylko WEWNĄTRZ zdania (rozdzielacze: `.`, `!`, `?`) — nie cross-sentence
- Eskalacja do dependency parsing (kwestia C) tylko jeśli sanity test pokaże problem

### 9.3 0-match handling: NA + osobna kolumna n_articles_with_signal

- `summarize_per_article()`: artykuł bez ANI JEDNEGO dopasowania → `score = NA, n_pos = 0, n_neg = 0`, NIE 0
- `summarize_per_ticker()`: dodaje kolumnę `n_articles_with_signal` (count tylko artykułów ze `score != NA`)
- Mean per ticker: NA pomija (`mean(..., na.rm = TRUE)`)
- Raport: dwie tabele — "Ranking medialny (tylko tickery z sygnałem)" + "Tickery bez nacechowanego pokrycia"
- Rozróżnia "neutralny ton" (balans pos-neg=0) od "brak nacechowania" (zero słów sentymentalnych)

### 9.4 Multi-ticker articles: konfigurowalny threshold, default 5

- Każdy artykuł może mieć N tickerów z `relevance_score` z `assign_tickers.R` (próg tam: `>=2`)
- Dla sentymentu DODATKOWY threshold w `src/common/constants.R`:
  ```r
  constants$sentiment_ticker_min_relevance <- 5  # zacznijmy od 5, łatwo zmienić
  ```
- Filtr ZASTOSOWANY przed `summarize_per_ticker()`: tylko pary `article × ticker` z `relevance_score >= 5` liczą się do sentymentu per ticker
- Z obecnym manifest (5 artykułów) odpadają: PEO (relevance=2 w mBank article), ING (relevance=3 w Złoty Bankier 2026)
- Full attribution dla zachowanych par: ticker dziedziczy pełny score artykułu
- Konfigurowalne — łatwa eksploracja po wynikach na 2k artykułów (0 = wszystkie, 3 = średnio, 5 = strict, 10 = tylko top mentions)
- Raport pokazuje próg użyty + sanity check "zmiana progu z 5 na 3 zmienia ranking tak: ..."

## Część 10: Higiena repo — co commitujemy, co nie

**Zasada:** w repo zostają tylko (a) **kod** (skrypty R/Rmd), (b) **finalne artefakty** (CSV słowników wyjściowych, CSV/PNG wynikowe analizy), (c) **raport HTML**. Wszystkie pliki robocze / pośrednie / źródłowe-do-przetworzenia idą do **workspace POZA repo** (default: `~/wse_workspace/wse-sentiment/`).

### Pliki COMMITOWANE do repo

```
src/
  sentiment.R                       ← kod
  clustering.R                      ← kod
  build_plwordnet_csv.R             ← kod (one-shot parser)
  build_lm_pl.R                     ← kod (one-shot DeepL)
  build_lm_pl_topfreq.R             ← kod
  apply_lm_pl_review.R              ← kod
  common/
    text_pipeline.R                 ← kod
    constants.R                     ← kod (modyfikowany)

dataset/
  dictionaries/
    plwordnet_emo.csv               ← OUTPUT (~31k wierszy, ~2MB)
    sentiment_lm_pl.csv             ← OUTPUT (~4150 wierszy)
    sentiment_pl_custom.csv         ← INPUT manual (~30 wierszy)
    stopwords_custom_pl.csv         ← INPUT manual (~20 wierszy)
  raw/                              ← już istniejące
  processed/                        ← OUTPUTy analizy
    sentiment_per_article.csv
    sentiment_per_ticker.csv
    sentiment_timeline.csv
    topics_lda.csv
    article_topic_gamma.csv
    tfidf_per_ticker.csv
    word_freq.csv

assets/
  figures/                          ← OUTPUTy PNG (do raportu)
  udpipe/polish-pdb-...udpipe       ← już istniejący model

report/
  raport.Rmd                        ← kod raportu
  raport.html                       ← OUTPUT (decyzja w .gitignore poniżej)

tests/testthat/
  test_sentiment.R                  ← kod
  test_clustering.R                 ← kod
```

### Pliki POZA repo (workspace user'a, default `~/wse_workspace/wse-sentiment/`)

```
~/wse_workspace/wse-sentiment/
  raw/
    wordnet_work_4_5.zip            ← raw download CLARIN-PL (444MB)
    wordnet_work_4_5.sql            ← unpacked dump (2.6GB)
    plwn_filtered.txt               ← intermediate awk-filtered SQL
  cache/
    lm_translations_raw.csv         ← cache DeepL (checkpoint dla wznawiania)
  review/
    lm_pl_top200.csv                ← raw output do manual review (user edytuje INPLACE)
    lm_pl_top200_REVIEWED.csv       ← po manual review (input dla apply_lm_pl_review.R)
```

### `.gitignore` — dodać wpisy

```
# plWordNet raw dump (download poza repo, nie commitujemy)
*.zip
*.sql
wordnet_work_*.zip
wordnet_work_*.sql

# Workspace (gdyby user przypadkiem skopiował do repo)
dataset/dictionaries/_cache/
dataset/dictionaries/_review/
dataset/dictionaries/_workspace/
dataset/dictionaries/_raw/

# DeepL cache
*_translations_raw.csv

# R session
.Rhistory
.RData
.Rproj.user/
```

### Konfiguracja workspace w constants.R

```r
# Workspace path — zewnętrzny względem repo, default w home usera
# Można nadpisać przez env var WSE_WORKSPACE
constants$workspace_dir <- Sys.getenv(
  "WSE_WORKSPACE",
  unset = file.path(Sys.getenv("HOME"), "wse_workspace", "wse-sentiment")
)
constants$workspace_raw <- file.path(constants$workspace_dir, "raw")
constants$workspace_cache <- file.path(constants$workspace_dir, "cache")
constants$workspace_review <- file.path(constants$workspace_dir, "review")
```

Skrypty `build_*.R` używają `constants$workspace_*` dla wszystkich pośrednich plików. Pliki finalne (CSV słowników) zapisują się do `dataset/dictionaries/` (w repo).

### Cleanup checklist (Sesja 3, końcówka)

1. `git status` — sprawdź czy żaden plik pośredni nie wszedł przypadkiem do staging
2. `git ls-files | grep -E '\.(zip|sql)$'` — powinno być puste
3. `du -sh dataset/dictionaries/` — sprawdź rozmiar (powinno być < 5MB total dla CSV)
4. Sprawdź `.gitignore` ma wszystkie wpisy
5. Sprawdź czy `~/wse_workspace/wse-sentiment/` ma WSZYSTKIE pliki tymczasowe (czyli były pisane tam, nie do repo)
6. `report/raport.html` jest w repo (wygenerowany artefakt zaliczeniowy)
7. Commit z message wskazującym że workspace files są poza repo

### Raport HTML — decyzja: commit w repo

`report/raport.html` jest commitowany do repo jako wygenerowany finalny artefakt zaliczeniowy. Regenerujemy ręcznie po każdej znaczącej zmianie kodu/danych (`Rscript -e 'rmarkdown::render("report/raport.Rmd")'`). Prowadzący widzi gotowy raport bez konieczności renderowania.

## Otwarte do iteracji w trakcie implementacji

- Dokładny rozmiar `sentiment_pl_custom.csv` (start ~30, dorzucanie podczas debugowania sanity testu)
- `k` w LDA (start 5 dla 2k artykułów, 2-3 dla 5 testowych)
- Próg `removeSparseTerms` w DTM (start 0.99)
- Wybór timeline granularity dla sentyment indexu (week vs day, zależy od gęstości artykułów w czasie)
