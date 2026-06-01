FROM rocker/r-ver:4.5.3

RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libuv1-dev \
    libx11-dev \
    libgsl-dev \
    cmake \
    curl \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY renv.lock .Rprofile ./
COPY renv/activate.R renv/

RUN Rscript -e 'renv::restore()'

COPY . .

CMD ["bash"]
