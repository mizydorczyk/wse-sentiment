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
