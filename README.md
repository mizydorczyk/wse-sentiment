# wse-sentiment

A reproducible R pipeline to transform financial news (`bankier.pl`) into company-level market signals for the Warsaw Stock Exchange (WSE / GPW).

For a detailed, non-technical overview of the project's goals, architecture, and processing modules, please read the [specification](specs.md).

## How to setup a project?

1. Clone the repository  
    ```bash
    git clone <repository-url>
    cd wse-sentiment
    ```

2. Open the project in R  
Start an R session in the project's root directory (or open the project in RStudio). The included `.Rprofile` will automatically bootstrap the `renv` environment.

3. Restore dependencies  
Run the following command in your R console to download and install the exact package versions specified in the `renv.lock` file:
    ```R
    renv::restore()
    ```

## How to run?

### With Docker

Build the image and run the scripts:

```bash
docker build -t wse-sentiment .
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/collect_rss.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/deduplicate_feeds.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/scrape_articles.R
docker run --rm -v $(pwd)/dataset:/app/dataset wse-sentiment Rscript src/assign_tickers.R
```

### Without Docker

Run the scripts directly from your terminal:

```bash
Rscript src/collect_rss.R
Rscript src/deduplicate_feeds.R
Rscript src/scrape_articles.R
Rscript src/assign_tickers.R
```

## How to run tests?

```bash
Rscript -e 'testthat::test_dir("tests/testthat", reporter="progress", chdir = TRUE)'
```
