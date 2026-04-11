# Specification

This system collects financial news and articles from the `bankier.pl` RSS feed, identifies the publicly traded companies they discuss, and analyzes the underlying sentiment of the text. Furthermore, it compares these narrative trends against actual historical stock prices from the Warsaw Stock Exchange (WSE / GPW) to identify potential market correlations.

It relies on historical data previously collected and stored in the `dataset/` directory. This approach allows us to evaluate the pipeline's performance, refine sentiment models, and test hypotheses against past market conditions in a stable environment.

The system architecture is designed in a modular way so that a live mode (which would continuously monitor the feed in real-time for immediate signal generation) can be easily implemented in the future once the backtesting proves successful.

## Structure

```text
wse-sentiment/
├── dataset/
│   ├── raw/
│   └── processed/
├── src/
│   ├── collect_rss.R
│   ├── scrape_articles.R
│   ├── parse_article.R
│   ├── assign_tickers.R
│   ├── sentiment.R
│   ├── clustering.R
│   └── correlation_gpw.R
├── report/
│   └── raport.Rmd
├── README.md
└── renv.lock
```

## Modules

### Collect RSS
The first step of the pipeline focuses on gathering data from the `bankier.pl` RSS feed—the sole data source for this project. For the current backtesting approach, this involves compiling a historical archive of headlines, publication times, and links to the full articles. This historical dataset serves as the foundation for all subsequent analysis.

### Scrape articles
Because RSS feeds usually only provide a short summary or headline, this module visits the original source links to extract the full text of the articles. Having the complete article body is crucial for understanding the full context and nuances required for accurate sentiment analysis.

### Assign tickers
Not every article explicitly lists the stock symbols of the companies it discusses. This module scans the full text of the gathered articles and intelligently maps them to specific companies listed on the Warsaw Stock Exchange. By assigning correct tickers, the system ensures that market signals are attributed to the right assets.

### Sentiment
Once the articles are mapped to companies, this module evaluates the tone of the text. It determines whether the news surrounding a specific company is positive, negative, or neutral. This creates a quantifiable metric that reflects how the media and public perceive the current state of that company.

### Clustering
Market movements are often driven by broader themes rather than isolated events. The clustering module groups similar articles together based on their content. By organizing the news into thematic clusters (such as "mergers and acquisitions", "earnings reports", or "macroeconomic policy"), the system helps identify large-scale narratives shaping the market.

### Correlation with the Warsaw Stock Exchange
The final module bridges the gap between media narratives and actual market behavior. It takes the sentiment scores and thematic clusters and compares them against historical price movements and trading volumes on the WSE. The goal is to discover if—and how strongly - the media's tone and topics correlate with the actual rise or fall of stock prices.
