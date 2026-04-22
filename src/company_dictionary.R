company_dictionary <- list(
  # WIG20
  list(ticker = "ALR", stems = c("Alior"), exact_phrases = c("Alior Bank")),
  list(ticker = "ACP", stems = c("Asseco"), exact_phrases = c("Asseco Poland")),
  list(ticker = "BDX", stems = c("Budimex", "Budimek"), exact_phrases = c("Grupa Budimex")),
  list(ticker = "CCC", acronyms = c("CCC"), exact_phrases = c("Grupa CCC")),
  list(
    ticker = "CDR",
    exact_phrases = c("CD Projekt", "CD Projekt Red", "CD Projektu", "CD Projekcie", "CD Projektem")
  ),
  list(ticker = "CPS", stems = c("Cyfrowy Polsat", "Cyfrowego Polsat", "Polsat")),
  list(ticker = "DNP", stems = c("Dino"), exact_phrases = c("Dino Polska")),
  list(
    ticker = "JSW",
    acronyms = c("JSW"),
    exact_phrases = c("Jastrzębska Spółka Węglowa", "Jastrzębskiej Spółce Węglowej")
  ),
  list(ticker = "KTY", stems = c("Kęt"), exact_phrases = c("Grupa Kęty", "Grupy Kęty", "Grupę Kęty")),
  list(ticker = "KGH", acronyms = c("KGHM"), exact_phrases = c("KGHM Polska Miedź")),
  list(ticker = "KRU", stems = c("Kruk"), exact_phrases = c("Grupa Kruk"), strict_case = TRUE),
  list(ticker = "LPP", acronyms = c("LPP"), exact_phrases = c("Grupa LPP")),
  list(ticker = "MBK", stems = c("mBank")),
  list(ticker = "OPL", stems = c("Orange"), exact_phrases = c("Orange Polska"), strict_case = TRUE),
  list(ticker = "PEO", stems = c("Pekao"), exact_phrases = c("Bank Pekao")),
  list(
    ticker = "PGE",
    acronyms = c("PGE"),
    exact_phrases = c("Polska Grupa Energetyczna", "Polskiej Grupy Energetycznej")
  ),
  list(ticker = "PKN", stems = c("Orlen"), acronyms = c("PKN"), exact_phrases = c("PKN Orlen")),
  list(ticker = "PKO", acronyms = c("PKO", "PKO BP"), exact_phrases = c("PKO Bank Polski", "PKO Banku Polskiego")),
  list(ticker = "PZU", acronyms = c("PZU"), exact_phrases = c("Powszechny Zakład Ubezpieczeń")),
  list(ticker = "SPL", stems = c("Santander"), exact_phrases = c("Santander Bank Polska")),

  # mWIG40
  list(ticker = "11B", stems = c("11 bit", "11bit"), exact_phrases = c("11 bit studios")),
  list(ticker = "APR", exact_phrases = c("Auto Partner", "Auto Partnera", "Auto Partnerem")),
  list(ticker = "ATC", stems = c("Arctic", "Arctic Paper")),
  list(ticker = "ASB", stems = c("Astarta")),
  list(
    ticker = "BHW",
    exact_phrases = c(
      "Bank Handlowy",
      "Banku Handlowego",
      "Bankiem Handlowym",
      "Citi Handlowy",
      "Citi Handlowego",
      "Citi Handlowym"
    )
  ),
  list(ticker = "BOS", acronyms = c("BOŚ"), exact_phrases = c("Bank Ochrony Środowiska", "Banku Ochrony Środowiska")),
  list(ticker = "BFT", stems = c("Benefit", "Benefit Systems")),
  list(ticker = "CAR", stems = c("Intercars"), exact_phrases = c("Inter Cars", "Inter Carsu", "Inter Carsem")),
  list(ticker = "CIE", stems = c("Ciech")),
  list(ticker = "CMR", stems = c("Comarch")),
  list(ticker = "COG", stems = c("Cognor")),
  list(ticker = "DOM", exact_phrases = c("Dom Development", "Domu Development", "Domem Development")),
  list(ticker = "DVL", stems = c("Develia", "Develi")),
  list(ticker = "EAT", stems = c("AmRest")),
  list(ticker = "ENA", stems = c("Enea", "Enei")),
  list(ticker = "EUR", stems = c("Eurocash")),
  list(ticker = "GEA", stems = c("Grenevia", "Famur")),
  list(
    ticker = "GPW",
    exact_phrases = c(
      "GPW S.A.",
      "Grupa GPW",
      "Grupy GPW",
      "Grupie GPW",
      "Giełda Papierów Wartościowych S.A.",
      "Giełdy Papierów Wartościowych S.A.",
      "GPW SA"
    )
  ),
  list(ticker = "GRX", stems = c("GreenX"), exact_phrases = c("GreenX Metals", "GreenX Metalsu")),
  list(ticker = "HWE", stems = c("Huuuge"), exact_phrases = c("Huuuge Games", "Huuuge Gamesu")),
  list(ticker = "ING", acronyms = c("ING"), exact_phrases = c("ING Bank Śląski", "Bank Śląski")),
  list(ticker = "LWB", stems = c("Bogdank", "Bogdanka", "Lubelski Węgiel Bogdanka")),
  list(ticker = "MAB", stems = c("Mabion")),
  list(ticker = "MIL", stems = c("Millennium"), exact_phrases = c("Bank Millennium")),
  list(ticker = "NEU", stems = c("Neuca", "Neuc")),
  list(ticker = "PKP", exact_phrases = c("PKP Cargo")),
  list(ticker = "RVC", stems = c("Ryvu"), exact_phrases = c("Ryvu Therapeutics", "Ryvu Therapeuticsu")),
  list(ticker = "TEN", exact_phrases = c("Ten Square", "Ten Square Games", "Ten Square Gamesu")),
  list(ticker = "TPE", stems = c("Tauron"), exact_phrases = c("Tauron Polska Energia")),
  list(
    ticker = "TXT",
    stems = c("Text", "LiveChat"), exact_phrases = c("LiveChat Software", "LiveChatu", "LiveChatem", "Textu", "Textem")
  ),
  list(ticker = "WPL", acronyms = c("WP"), exact_phrases = c("Wirtualna Polska", "Wirtualnej Polski", "WP Holding")),
  list(ticker = "XTB", acronyms = c("XTB"), exact_phrases = c("X-Trade Brokers")),
  list(ticker = "AGO", stems = c("Agor", "Agora"), strict_case = TRUE),
  list(ticker = "BML", stems = c("Bumech")),
  list(ticker = "DAT", stems = c("DataWalk")),
  list(ticker = "MDG", exact_phrases = c("Medicalgorithmics", "Medicalgorithmicsu", "Medicalgorithmicsowi")),
  list(ticker = "MRC", stems = c("Mercator"), exact_phrases = c("Mercator Medical", "Mercatora Medical")),
  list(ticker = "MRB", stems = c("Mirbud")),
  list(ticker = "PLW", stems = c("PlayWay")),
  list(ticker = "SLV", stems = c("Selena"), exact_phrases = c("Selena FM", "Seleny FM"))
)
