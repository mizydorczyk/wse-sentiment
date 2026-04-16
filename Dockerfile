FROM rocker/r-ver:4.3.2

RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY renv.lock .Rprofile ./
COPY renv/activate.R renv/

RUN Rscript -e 'renv::restore()'

COPY . .

CMD ["bash"]
