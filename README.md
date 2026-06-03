# wse-sentiment

A reproducible R pipeline to transform financial news (`bankier.pl`) into company-level market signals for the Warsaw Stock Exchange (WSE / GPW).

For a detailed, non-technical overview of the project's goals, architecture, and processing modules, please read the [specification](specs.md).

## How to setup a project?

1. Clone the repository  
    ```bash
    git clone <repository-url>
    cd wse-sentiment
    ```

2. Unlock encrypted data files  
The raw dataset is encrypted with `git-crypt`. Unlock it before running the
pipeline or mounting `dataset/` into Docker:
    ```bash
    git-crypt unlock /path/to/key
    ```

If the data is still locked, article files will start with `GITCRYPT` instead
of JSON and the R scripts will fail with a JSON parse error.

3. Open the project in R  
Start an R session in the project's root directory (or open the project in RStudio). The included `.Rprofile` will automatically bootstrap the `renv` environment.

4. Restore dependencies  
Run the following command in your R console to download and install the exact package versions specified in the `renv.lock` file:
    ```R
    renv::restore()
    ```

## How to run?

### With Docker

Build the image and run the scripts:

Make sure the repository is unlocked with `git-crypt unlock /path/to/key` before
running these commands. Docker mounts the host `dataset/` directory as-is, so
locked files cannot be parsed inside the container.

```bash
docker build -t wse-sentiment .
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/collect_rss.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/deduplicate_feeds.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/scrape_articles.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/assign_tickers.R

docker run --rm \
  -v $(pwd)/dataset:/app/dataset \
  -v $(pwd)/assets/figures:/app/assets/figures \
  wse-sentiment Rscript src/sentiment.R

docker run --rm \
  -v $(pwd)/dataset:/app/dataset \
  -v $(pwd)/assets/figures:/app/assets/figures \
  wse-sentiment Rscript src/clustering.R

docker run --rm \
  -v $(pwd)/dataset:/app/dataset \
  -v $(pwd)/assets/figures:/app/assets/figures \
  -v $(pwd)/report:/app/report \
  wse-sentiment Rscript -e 'rmarkdown::render("report/raport.Rmd", knit_root_dir = getwd(), output_dir = "/app/report", intermediates_dir = getwd())'
```

The generated report is written to `report/raport.html`.

### Without Docker

Run the scripts directly from your terminal:

```bash
Rscript src/collect_rss.R
Rscript src/deduplicate_feeds.R
Rscript src/scrape_articles.R
Rscript src/assign_tickers.R
Rscript src/sentiment.R
Rscript src/clustering.R
Rscript -e 'rmarkdown::render("report/raport.Rmd", knit_root_dir = getwd(), output_dir = getwd(), intermediates_dir = getwd())' && mv -f raport.html report/raport.html && rm -f raport.knit.md
```

The generated report is written to `report/raport.html`.

## How to run tests?

### With Docker

```bash
docker build -t wse-sentiment .
docker run --rm \
  -v $(pwd)/dataset:/app/dataset \
  -v $(pwd)/assets/figures:/app/assets/figures \
  wse-sentiment Rscript -e 'testthat::test_dir("tests/testthat", reporter="progress", chdir = TRUE)'
```

### Without Docker

```bash
Rscript -e 'testthat::test_dir("tests/testthat", reporter="progress", chdir = TRUE)'
```

## Contributions

- [mizydorczyk](https://github.com/mizydorczyk) -- idea, articles scraping, CI/CD, assign tickers  
- [natalialisznianska](https://github.com/natalialisznianska) -- SRS documentation  
- [Yel1owHatGuy](https://github.com/Yel1owHatGuy) -- clustering, sentiment analysis, HTML report  

Honorable mentions include OpenAI's Codex and Anthropic's Claude Code.
