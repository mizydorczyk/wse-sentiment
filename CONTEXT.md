# Kontekst projektu wse-sentiment — notatka dla Claude

Projekt zaliczeniowy z przedmiotu "Projektowanie Systemów Informatycznych 2026".
Repo: `~/repo/wse-sentiment`, branch roboczy: `fzablocki`.
Deadline: **07.06.2026 23:59** (link do GitHub w arkuszu Google).

---

## Co projekt musi zawierać

**Część I — Reproducible Research (25 pkt):**
- Skrypt R + dane — 20 pkt
- Raport HTML wygenerowany ze skryptu R — 5 pkt

**Część II — Dokumentacja SRS (25 pkt):** wprowadzenie, cele systemu, wymagania funkcjonalne i niefunkcjonalne, interfejsy/dane, słownictwo, use cases, user stories.

**Wymagania techniczne:**
- minimum **2 z technik**: analiza częstości słów, analiza sentymentu, klastrowanie, topic modeling, asocjacje, TF-IDF, klasyfikacja
- użytkownik musi móc uruchomić analizę na dostarczonych danych
- wizualizacje (ggplot2, chmury słów)
- czytelny kod, podział na sekcje, komentarze

**Bezpieczny wybór technik:** text mining (częstość + wordcloud) + sentyment (tidytext/leksykony) + LDA lub klastrowanie. TF-IDF i klasyfikacja były w wymaganiach ale nie pojawiły się w plikach z zajęć — lepiej ich unikać.

---

## Stan repo — co już istnieje

### Gotowe moduły (`src/`)

| Plik | Co robi |
|------|---------|
| `collect_rss.R` | Pobiera 5 RSS feedów z bankier.pl → `dataset/raw/rss.csv` |
| `collect_archive.R` | Crawluje historyczne strony archiwum bankier.pl → `dataset/raw/archive.csv` |
| `deduplicate_feeds.R` | Merge RSS + archive, normalizacja URL, MD5 jako ID → `dataset/raw/feeds.csv` |
| `scrape_articles.R` | Scrape pełnych artykułów z bankier.pl → JSON per artykuł + manifest |
| `parse_article.R` | Parsuje HTML artykułu → title, label, author, lead, paragraphs, headings, links, images |
| `assign_tickers.R` | Przypisuje tickery GPW przez NLP (udpipe model PL) + regex; scoring title×5, lead×3, body×1 |
| `company_dictionary.R` | Słownik WIG20 + mWIG40 + sWIG80 ze stems/acronyms/exact_phrases |

### Testy

- `tests/testthat/test_unit_assign_tickers.R` — 7 unit testów (regex, kompilacja słownika, puste wejście)
- `tests/testthat/test_eval_annotated_set.R` — eval precision/recall na ground truth (12 artykułów, 100%/100%)
- `tests/fixtures/ground_truth_articles.json` — wypełnione (12 artykułów z expected_tickers)

Uruchomienie testów:
```bash
Rscript -e 'testthat::test_dir("tests/testthat", reporter="progress", chdir = TRUE)'
```

### Czego brakuje (per specs.md)

Pliki wymienione w `specs.md` ale **nieistniejące**:
- `src/sentiment.R` — analiza sentymentu per ticker (**następny krok**)
- `src/clustering.R` — grupowanie artykułów tematycznie
- `src/correlation_gpw.R` — korelacja z cenami akcji GPW (brak też danych cenowych)
- `report/raport.Rmd` — raport HTML (wymagane do zaliczenia)

Brakuje też dokumentu SRS (Część II zaliczenia).

---

## Środowisko

**R:** 4.5.3 (zainstalowany z CRAN noble-cran40, pinowany na 4.5.3 żeby pasować do renv.lock)
**renv:** lockfile zsynchronizowany, 60 pakietów zainstalowanych

Niestandardowe poprawki w renv.lock względem oryginału:
- `Rcpp`: 1.1.1-1 → 1.1.1-1.1 (wersja 1.1.1-1 nie była dostępna do pobrania)
- `ps`: zaktualizowane przez `renv::snapshot()` po instalacji

System deps wymagane (już zainstalowane): `libcurl4-openssl-dev`, `libuv1-dev`, `cmake`

### Workflow pushowania

1. Pracuj na branchu `fzablocki`
2. Pre-commit hook auto-odpala **styler** + **lintr** na staged `src/*.R` — jeśli styler zmieni plik, commit odrzucony, trzeba `git add` i commitować ponownie
3. CI na GitHub: `lint_and_check.yml` (push/PR do master: renv status + lintr), `deploy.yml` (push do master: deploy na VPS przez SCP+SSH)
4. Lokalnie potrzebne: `styler` i `lintr` w bibliotece R

---

## Dataset — przykładowe dane

5 artykułów z bankier.pl skopiowanych do `dataset/raw/articles/` (artykuły o bankach: Alior, ING, mBank, Pekao, Saxo):

```
dataset/raw/articles/          # 5 plików JSON (MD5 URL jako nazwa)
dataset/raw/articles_manifest.json  # indeks: {id, file, url, success, scraped_at, title, author}
dataset/processed/articles_manifest.json  # wygenerowany przez assign_tickers.R
```

Format artykułu JSON:
```json
{
  "metadata": { "url", "title", "article_label", "author", "publication_date", "scraped_at" },
  "content":  { "lead", "paragraphs", "headings", "links", "images": { "captions", "alts" } }
}
```

Format processed manifest (po assign_tickers):
```json
[{ "id", "file", "url", "tickers": [{ "ticker": "ALR", "relevance_score": 15 }] }]
```

Wyniki assign_tickers na przykładowych danych:
- ALR (Alior) — artykuł o awarii bankowości
- ING — 2 artykuły (premia dla klientów, ranking banków)
- MBK, SPL, ING, PEO — artykuł "mBank detronizuje lidera" (ranking złotych bankierów)
- brak tickera — artykuł o Saxo Bank (nie ma w słowniku)

---

## Planowanie sentiment.R — co ustalono

`sentiment.R` będzie następnym krokiem. Dane wejściowe:
- `dataset/raw/articles/*.json` — pełne artykuły
- `dataset/processed/articles_manifest.json` — tickery per artykuł

Tekst do analizy: `lead` + `paragraphs` sklejone per artykuł, per ticker.

Techniki do wyboru (ustalić z użytkownikiem):
1. **Słownikowa (tidytext + leksykony)** — `inner_join` z bing/afinn/loughran. Loughran-McDonald jest finansowy, dobry dla tego projektu. Wynik: score positive/negative per ticker.
2. **SentimentAnalysis** — `analyzeSentiment()` ze słownikami GI/HE/LM (LM = Loughran-McDonald financial). Zwraca numeryczny score.
3. **Sentyment w czasie** — chunki tekstu chronologicznie, wykres `geom_line`.

Dla wymagań zaliczeniowych: wystarczy 1 podejście do sentymentu + 1 inna technika (np. LDA lub klastrowanie).

---

## Techniki z zajęć — pakiety i kod

Referencja z `~/Downloads/PSI_2026_projekt_tutorial.md`:

### Pakiety do zainstalowania

```r
install.packages(c(
  "tm", "SnowballC", "stringr", "tidytext", "textdata",
  "SentimentAnalysis", "topicmodels", "cluster", "factoextra",
  "tidyverse", "ggthemes", "ggrepel", "wordcloud", "RColorBrewer",
  "DT", "knitr", "rmarkdown", "stringi"
))
```

Uwaga: `textdata` przy pierwszym `get_sentiments("afinn"/"nrc"/"loughran")` pyta o akceptację licencji w konsoli. Alternatywa: wczytaj z lokalnych CSV (są w repo zajęć `04.Zajecia/_Slowniki_w_CSV/`: `afinn.csv`, `bing.csv`, `nrc.csv`, `loughran.csv`).

### 1. Analiza częstości słów (tekst mining)

```r
# pipeline na surowym tekście
text <- tolower(readLines(file_path, encoding = "UTF-8"))
text <- removePunctuation(text)  # tm
text <- removeNumbers(text)
text <- removeWords(text, stopwords("pl"))  # lub "en"
words <- unlist(strsplit(text, "\\s+"))
words <- words[words != ""]
freq_df <- data.frame(word = names(table(words)), freq = as.integer(table(words))) |>
  arrange(desc(freq))

# wordcloud
wordcloud(words = freq_df$word, freq = freq_df$freq, min.freq = 3,
          colors = brewer.pal(8, "Dark2"))
```

### 2. Korpus tm + DTM/TDM

```r
corpus <- VCorpus(VectorSource(texts_vector))
corpus <- tm_map(corpus, content_transformer(tolower))
corpus <- tm_map(corpus, removeNumbers)
corpus <- tm_map(corpus, removeWords, stopwords("polish"))  # lub "english"
corpus <- tm_map(corpus, removePunctuation)
corpus <- tm_map(corpus, stripWhitespace)

dtm <- DocumentTermMatrix(corpus)   # dokumenty w wierszach
tdm <- TermDocumentMatrix(corpus)   # tokeny w wierszach
dtm_m <- as.matrix(dtm)
```

### 3. Analiza sentymentu — tidytext + leksykony

```r
library(tidytext); library(dplyr)

# leksykony:
# get_sentiments("bing")     — positive/negative ~6800 słów
# get_sentiments("afinn")    — value -5..+5
# get_sentiments("nrc")      — 10 emocji + pos/neg
# get_sentiments("loughran") — finansowy: positive/negative/litigious/uncertainty/...

tidy_tokens <- tibble(word = words)  # lub unnest_tokens(word, text)
sentiment_df <- tidy_tokens |>
  inner_join(get_sentiments("loughran"), relationship = "many-to-many")

word_counts <- sentiment_df |>
  filter(sentiment %in% c("positive", "negative")) |>
  group_by(sentiment) |>
  top_n(20, n) |>
  ungroup()

ggplot(word_counts, aes(x = reorder(word, n), y = n, fill = sentiment)) +
  geom_col(show.legend = FALSE) +
  facet_wrap(~sentiment, scales = "free") +
  coord_flip() +
  scale_fill_manual(values = c("firebrick", "darkolivegreen4"))
```

### 4. Analiza sentymentu — SentimentAnalysis

```r
library(SentimentAnalysis)

sentiment <- analyzeSentiment(text_vector)
# kolumny: SentimentGI, SentimentHE, SentimentLM, SentimentQDAP

sentimentLM <- convertToDirection(sentiment$SentimentLM)  # negative/neutral/positive
```

### 5. Sentyment w czasie (chunki)

```r
split_text_into_chunks <- function(text, chunk_size) {
  start_positions <- seq(1, nchar(text), by = chunk_size)
  substring(text, start_positions, start_positions + chunk_size - 1)
}
chunks <- split_text_into_chunks(full_text, 200)
sentiment <- analyzeSentiment(chunks)
# wykres geom_line() / geom_smooth() po osi chunk index
```

### 6. Klastrowanie kMeans

```r
library(cluster); library(factoextra)

# dobór k
fviz_nbclust(dtm_m, kmeans, method = "silhouette")

set.seed(123)
km <- kmeans(dtm_m, centers = 3)
fviz_cluster(list(data = dtm_m, cluster = km$cluster), geom = "point")

# wordcloud per klaster
for (i in 1:3) {
  cluster_docs <- dtm_m[km$cluster == i, , drop = FALSE]
  word_freq <- colSums(cluster_docs)
  wordcloud(names(word_freq), freq = word_freq, max.words = 15)
}
```

### 7. Topic modeling LDA

```r
library(topicmodels); library(tidytext)

# WAŻNE: usuń puste wiersze DTM przed LDA
unique_indexes <- unique(dtm$i)
dtm_clean <- dtm[unique_indexes, ]

lda <- LDA(dtm_clean, k = 3, control = list(seed = 1234))
topics <- tidy(lda, matrix = "beta")

topics |>
  group_by(topic) |>
  top_n(10, beta) |>
  ungroup() |>
  mutate(term = reorder(term, beta)) |>
  ggplot(aes(term, beta, fill = factor(topic))) +
  geom_col(show.legend = FALSE) +
  facet_wrap(~topic, scales = "free") +
  coord_flip()
```

### 8. Asocjacje

```r
findAssocs(tdm, "bank", 0.4)  # słowa skorelowane z "bank" r >= 0.4

# wizualizacja lollipop
assoc_df <- data.frame(word = names(assoc_sorted), score = assoc_sorted)
ggplot(assoc_df, aes(x = score, y = reorder(word, score))) +
  geom_segment(aes(x = 0, xend = score, y = word, yend = word)) +
  geom_point(size = 3)
```

### 9. Raport HTML ze skryptu R

```r
#' ---
#' title: "Analiza sentymentu artykułów finansowych - GPW"
#' author: ""
#' date: "`r Sys.Date()`"
#' output:
#'   html_document:
#'     theme: readable
#'     highlight: kate
#'     toc: true
#'     toc_float: true
#'     code_folding: hide
#'     number_sections: true
#' ---

knitr::opts_chunk$set(message = FALSE, warning = FALSE)

#' # Sekcja — nagłówek H1
# zwykły komentarz (nie pojawi się w raporcie)

# render:
rmarkdown::render("src/sentiment.R")
```

`#'` = markdown w raporcie, `#` = komentarz w kodzie.

### Pułapki techniczne

- `get_sentiments()` pyta o licencję przy pierwszym użyciu — użyj CSV z repo zajęć jako alternatywa
- `stemCompletion` zwraca puste stringi — usuń: `completed_doc[completed_doc != ""]`
- LDA wybucha na pustych wierszach DTM — zawsze filtruj przez `unique(dtm$i)`
- `relationship = "many-to-many"` wymagane przy `inner_join` z NRC/Loughran (dplyr 1.1+)
- `set.seed()` zawsze przy kmeans i LDA
- `min.freq` w wordcloud — przy małych korpusach (5 artykułów) ustaw na 1 lub 2
- Apostrofy U+2019 vs U+0027 — normalizuj: `gsub("[''`´]", "'", text)`
- Stopwords polskie: `tm::stopwords("polish")` lub własna lista

---

## Repo z zajęć

`~/repo/Projektowanie_systemow_informatycznych_2026`, branch `fzablocki/claude`

Dane dostępne w tym repo:
- `04.Zajecia/_Slowniki_w_CSV/`: `afinn.csv`, `bing.csv`, `nrc.csv`, `loughran.csv` — leksykony bez konieczności `textdata`
- `07/textfolder/` — 8 opisów filmów (dobre do klastrowania)
- `08/textfolder2/` — 20 opisów filmów
- `09/textfolder3/` — 29 krótkich tekstów
- `10/LOT_reviews.csv` — 100 recenzji LOT Polish Airlines (kolumny: `Review_Text`, `Overall_Rating`, `Recommended`)

---

## Następne kroki

1. Zainstaluj pakiety do analizy (tm, tidytext, SentimentAnalysis, topicmodels itp.) do projektu renv
2. Napisz `src/sentiment.R` — analiza sentymentu artykułów per ticker (ustalić z użytkownikiem podejście: tidytext vs SentimentAnalysis)
3. Napisz `src/clustering.R` lub zintegruj LDA w raporcie
4. Napisz `report/raport.Rmd` — raport HTML (wymagany do zaliczenia)
5. Napisz dokument SRS (Część II)

Dla zaliczenia wystarczą **2 techniki** — bezpieczny wybór: sentyment (tidytext/Loughran) + LDA topic modeling. Raport HTML jest wymagany osobno za 5 pkt.
