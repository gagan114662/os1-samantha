import Foundation

struct CompanyTemplate: Identifiable, Codable, Hashable {
    enum Category: String, Codable, CaseIterable, Hashable {
        case digitalProducts = "Digital products"
        case kdp = "Amazon KDP"
        case creatorMedia = "Creator media"
        case newsletter = "Newsletter"
        case leadGeneration = "Lead generation"
        case realEstate = "Real estate"
        case automationService = "AI automation service"
        case microSaaS = "Micro-SaaS"
        case affiliate = "Affiliate"
        case productizedService = "Productized service"
    }

    let id: String
    let title: String
    let category: Category
    let channel: String
    let mission: String
    let validationSignals: [String]
    let launchAssets: [String]
    let riskNotes: [String]
    let suggestedCadenceMinutes: Int

    var searchText: String {
        ([title, category.rawValue, channel, mission] + validationSignals + launchAssets + riskNotes)
            .joined(separator: " ")
            .lowercased()
    }

    var companyName: String {
        title
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "-")
    }

    var missionPrompt: String {
        """
        Build this autonomous company template: \(title).

        Business model: \(category.rawValue)
        Primary channel: \(channel)
        Mission: \(mission)

        Validation signals to collect before scaling:
        \(validationSignals.map { "- \($0)" }.joined(separator: "\n"))

        Launch assets to create:
        \(launchAssets.map { "- \($0)" }.joined(separator: "\n"))

        Risk notes and constraints:
        \(riskNotes.map { "- \($0)" }.joined(separator: "\n"))

        Operating rule: validate demand first, ship the smallest monetizable asset, measure real revenue, and write kill/scale recommendation into JOURNAL.md and REVENUE.md.
        """
    }
}

enum CompanyTemplateCatalog {
    static let all: [CompanyTemplate] = [
        digital("etsy-wedding-canva-invitations", "Etsy wedding Canva invitation bundles", "Etsy", "Create editable wedding invitation, RSVP, detail card, and thank-you Canva bundles for a specific wedding aesthetic.", ["Etsy autocomplete demand for the aesthetic", "At least 3 competitor listings with sales/reviews", "Long-tail keyword under target competition"], ["Canva template bundle", "Listing images", "SEO title/tags", "Delivery PDF"], ["Avoid copyrighted fonts/art", "No fake reviews"]),
        digital("etsy-baby-shower-invitations", "Etsy baby shower invitation bundles", "Etsy", "Create themed baby shower invitation bundles with matching games and signs.", ["Search demand by theme", "Competitor review velocity", "Pinterest trend support"], ["Canva templates", "Printable games", "Listing mockups"], ["Avoid trademarked characters", "Use original art"]),
        digital("etsy-realtor-social-templates", "Etsy realtor social media templates", "Etsy", "Sell Canva social templates for realtors focused on listings, open houses, and market updates.", ["Realtor template keyword demand", "Competitor price/review analysis", "Realtor pain evidence"], ["50-post Canva pack", "Usage guide", "Etsy listing"], ["No MLS/logo misuse", "Generic compliance disclaimer"]),
        digital("etsy-med-spa-instagram-templates", "Etsy med spa Instagram templates", "Etsy", "Sell polished Instagram templates for med spas promoting services, FAQs, before-care, and after-care.", ["Med spa search volume", "Competitor sales/reviews", "High-ticket buyer profile"], ["Canva post/story pack", "Brand palette variants", "Listing assets"], ["Avoid medical claims", "No before/after deception"]),
        digital("etsy-fitness-coach-content-templates", "Etsy fitness coach content templates", "Etsy", "Create content calendars and Canva templates for online fitness coaches.", ["Fitness coach buyer evidence", "Template bundle sales comps", "Keyword demand"], ["Canva pack", "30-day content calendar", "Caption swipe file"], ["Avoid health guarantees", "No unsafe advice"]),
        digital("etsy-student-notion-planner", "Etsy Notion planner for students", "Etsy", "Sell a Notion academic planner for students with assignments, exams, grade tracking, and weekly reviews.", ["Notion student planner demand", "Competitor reviews", "Back-to-school seasonality"], ["Notion template", "Setup guide", "Listing images"], ["No school trademark use"]),
        digital("etsy-adhd-routine-planner", "Etsy ADHD daily routine planner", "Etsy", "Create printable and fillable ADHD-friendly daily routine planners.", ["ADHD planner search demand", "Buyer pain in reviews", "Low-competition subniche"], ["Fillable PDF", "Printable PDF", "Listing images"], ["No medical cure claims", "Clear non-medical disclaimer"]),
        digital("etsy-budget-spreadsheet-bundle", "Etsy budget spreadsheet bundle", "Etsy", "Sell Google Sheets budget, debt payoff, and savings tracker templates.", ["Budget spreadsheet demand", "Competitor review count", "Price point validation"], ["Google Sheets template", "Instructions PDF", "Etsy listing"], ["No financial advice claims"]),
        digital("etsy-meal-prep-planner", "Etsy meal prep planner bundle", "Etsy", "Create meal prep planner, grocery list, pantry inventory, and recipe card printables.", ["Meal prep keyword demand", "Pinterest trend support", "Competitor bundle pricing"], ["Printable bundle", "Fillable version", "Listing mockups"], ["Avoid diet/health guarantees"]),
        digital("etsy-small-business-ops-templates", "Etsy small-business invoice/proposal templates", "Etsy", "Sell invoices, proposals, onboarding forms, and client trackers for freelancers and small businesses.", ["Business template demand", "Buyer reviews mention time-saving", "Niche profession variant"], ["Docs/Sheets templates", "Canva proposal", "Listing assets"], ["No legal/accounting advice"]),

        digital("etsy-photography-client-kit", "Etsy photography contract/questionnaire kit", "Etsy", "Create client questionnaires, shot lists, welcome guides, and non-legal workflow forms for photographers.", ["Photography form searches", "Competitor sales", "Niche by wedding/family/brand"], ["Form templates", "Welcome guide", "Listing images"], ["Avoid representing as legal contract"]),
        digital("etsy-pet-sitter-onboarding-kit", "Etsy pet sitter onboarding/forms kit", "Etsy", "Sell intake forms, care instructions, invoices, and update templates for pet sitters.", ["Pet sitter template demand", "Competitor review gaps", "Local-service operator pain"], ["PDF/forms bundle", "Canva updates", "Etsy listing"], ["No veterinary claims"]),
        digital("etsy-cleaning-business-forms", "Etsy cleaning business forms kit", "Etsy", "Create estimates, checklists, client intake, and follow-up forms for cleaning businesses.", ["Cleaning business template demand", "Competitor sales", "Pain in forums/reviews"], ["Forms bundle", "Quote template", "Checklist pack"], ["No legal guarantees"]),
        digital("etsy-airbnb-host-checklists", "Etsy Airbnb host checklist bundle", "Etsy", "Sell turnover checklists, guest message templates, inventory trackers, and house manual templates.", ["Host checklist searches", "Competitor review count", "Airbnb host pain evidence"], ["Checklist PDFs", "Message templates", "House manual"], ["Avoid Airbnb trademark misuse"]),
        digital("etsy-daycare-activity-packs", "Etsy daycare printable activity packs", "Etsy", "Create age-specific daycare activity, schedule, and parent communication printables.", ["Daycare printable demand", "Seasonal theme demand", "Competitor review analysis"], ["Printable pack", "Parent note templates", "Listing images"], ["Age safety disclaimers"]),
        digital("etsy-homeschool-worksheet-packs", "Etsy homeschool worksheet packs", "Etsy", "Sell grade/topic-specific homeschool worksheets and lesson trackers.", ["Worksheet search demand", "Curriculum gap evidence", "Competitor price/reviews"], ["Worksheet PDFs", "Answer keys", "Lesson tracker"], ["Original content only"]),
        digital("etsy-niche-hobby-coloring-pages", "Etsy coloring pages for niche hobbies", "Etsy", "Create original coloring page bundles for niche hobbies and audiences.", ["Long-tail search demand", "Low competitor count", "Printable buyer reviews"], ["Coloring PDFs", "Cover mockups", "Listing assets"], ["Avoid IP/trademarked characters"]),
        digital("etsy-low-ink-wall-art", "Etsy low-ink wall art printables", "Etsy", "Sell minimalist low-ink printable wall art for specific rooms, jobs, or aesthetics.", ["Aesthetic keyword demand", "Competitor sales/reviews", "Pinterest support"], ["Print files", "Size guide", "Mockups"], ["Original assets only"]),
        digital("etsy-resume-portfolio-kit", "Etsy resume/portfolio templates", "Etsy", "Create resume, cover letter, LinkedIn banner, and portfolio templates for a specific profession.", ["Profession-specific resume demand", "Competitor review gaps", "Job market support"], ["Docs/Canva templates", "Instructions", "Listing"], ["No job-outcome guarantees"]),
        digital("etsy-habit-tracker-bundles", "Etsy digital habit tracker bundles", "Etsy", "Sell habit, mood, sleep, and goal tracker bundles for printable and tablet use.", ["Tracker demand", "Competitor sales", "Niche angle evidence"], ["PDF bundle", "GoodNotes version", "Listing images"], ["No health claims"]),

        kdp("kdp-adhd-adult-workbook", "Amazon KDP niche workbook for ADHD adults", "Amazon KDP", "Publish an ADHD-friendly workbook for routines, focus, and planning.", ["Keyword demand", "Competing book BSR/reviews", "Review pain analysis"], ["Manuscript", "Interior PDF", "Cover", "KDP listing"], ["No medical advice", "Original content"]),
        kdp("kdp-kids-activity-theme", "Amazon KDP kids activity book by theme", "Amazon KDP", "Publish a kids activity book around a low-competition theme.", ["Theme keyword demand", "BSR validation", "Parent review gaps"], ["Interior", "Cover", "Description"], ["Age appropriateness", "No copyrighted characters"]),
        kdp("kdp-real-estate-investing-guide", "Amazon KDP real estate investing beginner guide", "Amazon KDP", "Publish a concise beginner guide and worksheet pack for real estate investors.", ["KDP keyword demand", "Competitor review gaps", "Lead magnet fit"], ["Guide manuscript", "Worksheets", "Cover"], ["No financial advice guarantees"]),
        kdp("kdp-local-travel-micro-guides", "Amazon KDP local travel micro-guides", "Amazon KDP", "Publish focused local travel guides for narrow audiences.", ["Search demand", "Low-competition destination", "Affiliate/local upsell potential"], ["Guide manuscript", "Map/checklist", "Cover"], ["Fact-check venue info"]),
        kdp("kdp-profession-prompt-books", "Amazon KDP prompt books for professions", "Amazon KDP", "Publish prompt and workflow books for a specific profession.", ["Profession AI adoption", "Keyword demand", "Competitor gap"], ["Prompt book", "Workflow examples", "Cover"], ["Avoid overclaiming results"]),
        kdp("kdp-special-diet-recipe-book", "Amazon KDP recipe book for special diets", "Amazon KDP", "Publish a recipe book for a specific dietary niche.", ["Diet keyword demand", "Competitor BSR", "Review pain"], ["Recipes", "Meal plan", "Cover"], ["No medical claims", "Ingredient accuracy"]),
        kdp("kdp-devotional-journal-niche", "Amazon KDP daily devotional/journal niche", "Amazon KDP", "Publish a devotional or reflection journal for a narrow audience.", ["Audience search demand", "Competitor reviews", "Seasonality"], ["Interior", "Prompts", "Cover"], ["Respect faith/community tone"]),
        kdp("kdp-interview-prep-workbook", "Amazon KDP interview prep workbook", "Amazon KDP", "Publish interview prep workbooks for one profession.", ["Job-title keyword demand", "Competing BSR", "Pain in forums"], ["Question bank", "Practice tracker", "Cover"], ["No hiring guarantees"]),
        kdp("kdp-small-business-startup-checklist", "Amazon KDP small-business startup checklist book", "Amazon KDP", "Publish a startup checklist workbook for one local-service business.", ["Business-type demand", "Low-competition niche", "Upsell to templates"], ["Checklist book", "Worksheets", "Cover"], ["No legal/tax advice"]),
        kdp("kdp-language-phrasebook-niche", "Amazon KDP language-learning phrasebook niche", "Amazon KDP", "Publish a phrasebook for a specific travel/work context.", ["Phrasebook demand", "Competitor reviews", "Audience specificity"], ["Phrasebook", "Audio upsell plan", "Cover"], ["Translation QA needed"]),

        media("youtube-personal-finance-explainers", "Faceless YouTube channel: personal finance explainers", "YouTube", "Run a faceless channel explaining personal finance basics with affiliate/newsletter monetization.", ["Keyword demand", "Competitor view velocity", "Affiliate fit"], ["Channel plan", "Scripts", "Thumbnails", "Upload schedule"], ["No financial advice guarantees"]),
        media("youtube-real-estate-market-updates", "Faceless YouTube channel: real estate market updates", "YouTube", "Create local/niche real estate market update videos with lead-gen monetization.", ["Market search demand", "Agent/investor sponsor fit", "View comps"], ["Scripts", "Charts", "Thumbnails", "Lead magnet"], ["Use sourced data"]),
        media("youtube-ai-tool-tutorials", "Faceless YouTube channel: AI tool tutorials", "YouTube", "Publish tutorials and comparisons for AI tools by profession.", ["Tool search demand", "Affiliate programs", "Competitor velocity"], ["Scripts", "Screen recordings", "Thumbnails"], ["Disclose affiliate links"]),
        media("youtube-local-business-case-studies", "Faceless YouTube channel: local business case studies", "YouTube", "Analyze local business growth stories and tactics.", ["Audience demand", "Sponsor fit", "Repeatable research"], ["Scripts", "Visuals", "Outreach list"], ["Avoid defamation/unverified claims"]),
        media("youtube-luxury-travel-rankings", "Faceless YouTube channel: luxury travel ranking videos", "YouTube", "Create ranking videos for luxury travel experiences with affiliate monetization.", ["Search demand", "Affiliate fit", "View comps"], ["Scripts", "Image/video sourcing plan", "Thumbnails"], ["Media rights clearance"]),
        media("youtube-startup-stories", "Faceless YouTube channel: true startup stories", "YouTube", "Publish researched startup story videos for founders/operators.", ["Startup topic demand", "Competitor view velocity", "Newsletter upsell"], ["Scripts", "Timeline visuals", "Thumbnails"], ["Fact-check claims"]),
        media("youtube-founder-book-summaries", "Faceless YouTube channel: book summaries for founders", "YouTube", "Create actionable business book summaries for founders.", ["Book/topic demand", "Affiliate/book links", "Competitor analysis"], ["Scripts", "Summary visuals", "Thumbnails"], ["Respect copyright; original summaries"]),
        media("youtube-home-improvement-cost-guides", "Faceless YouTube channel: home improvement cost guides", "YouTube", "Publish cost breakdown videos for home improvement projects.", ["Cost keyword demand", "Lead-gen fit", "Regional niches"], ["Scripts", "Cost tables", "Lead capture"], ["Use sourced estimates"]),
        media("youtube-career-advice-by-industry", "Faceless YouTube channel: career advice by industry", "YouTube", "Create career advice channels by job family with digital product upsells.", ["Job keyword demand", "Resume product fit", "View comps"], ["Scripts", "Thumbnails", "Lead magnet"], ["No job guarantees"]),
        media("youtube-niche-product-comparisons", "Faceless YouTube channel: niche product comparisons", "YouTube", "Publish comparison videos for a product category with affiliate monetization.", ["Buyer intent keywords", "Affiliate programs", "Product data availability"], ["Scripts", "Comparison tables", "Thumbnails"], ["Affiliate disclosure"]),

        newsletter("newsletter-ai-tools-dentists", "Newsletter: weekly AI tools for dentists", "Email newsletter", "Curate AI tools and automation workflows for dental practices.", ["Dentist audience reach", "Sponsor fit", "Signup conversion"], ["Landing page", "Issue template", "Sponsor list"], ["No medical advice"]),
        newsletter("newsletter-real-estate-investor-deals", "Newsletter: weekly real estate investor deals", "Email newsletter", "Send curated property/investor opportunities and market notes.", ["Investor list source", "Open rate", "Lead/sponsor fit"], ["Landing page", "Issue template", "Data pipeline"], ["Sourced data only"]),
        newsletter("newsletter-local-events-restaurants", "Newsletter: local events and restaurant openings", "Email newsletter", "Run a local discovery newsletter monetized by sponsors.", ["Local search/social demand", "Subscriber acquisition cost", "Sponsor interest"], ["Landing page", "Issue template", "Sponsor deck"], ["Fact-check event details"]),
        newsletter("newsletter-grants-funding-alerts", "Newsletter: grants and funding alerts", "Email newsletter", "Curate grants/funding alerts for a specific audience.", ["Audience keyword demand", "Signup rate", "Sponsor/affiliate fit"], ["Landing page", "Grant tracker", "Issue template"], ["Deadline accuracy"]),
        newsletter("newsletter-remote-jobs-profession", "Newsletter: remote jobs by profession", "Email newsletter", "Curate remote jobs for a specific profession with paid listings/affiliate monetization.", ["Job seeker demand", "Employer listing demand", "Open/click rate"], ["Landing page", "Job scrape rules", "Issue template"], ["Respect job board terms"]),
        newsletter("newsletter-small-business-software-deals", "Newsletter: software deals for small businesses", "Email newsletter", "Curate software deals and tool recommendations for small businesses.", ["Affiliate fit", "Signup conversion", "Click intent"], ["Landing page", "Deal tracker", "Issue template"], ["Affiliate disclosure"]),
        newsletter("newsletter-community-immigration-digest", "Newsletter: immigration/news digest for one community", "Email newsletter", "Publish a curated digest for one immigrant/community niche.", ["Community demand", "Subscriber acquisition", "Sponsor fit"], ["Landing page", "Source list", "Issue template"], ["No legal advice"]),
        newsletter("newsletter-freelancer-tax-tips", "Newsletter: tax tips for freelancers", "Email newsletter", "Curate freelancer tax deadlines, checklists, and tools.", ["Freelancer demand", "CPA sponsor fit", "Lead magnet conversion"], ["Landing page", "Checklist", "Issue template"], ["No tax advice; cite sources"]),
        newsletter("newsletter-niche-etf-explainers", "Newsletter: niche stock/ETF explainer digest", "Email newsletter", "Explain ETFs/stocks for a narrow audience with affiliate/newsletter monetization.", ["Search/social demand", "Signup rate", "Sponsor fit"], ["Landing page", "Issue template", "Disclosure"], ["No investment advice"]),
        newsletter("newsletter-etsy-seller-growth", "Newsletter: Shopify/Etsy seller growth tips", "Email newsletter", "Publish seller growth tactics and tool recommendations.", ["Seller audience demand", "Affiliate fit", "Open/click rate"], ["Landing page", "Issue template", "Lead magnet"], ["No income guarantees"]),

        lead("leadgen-roofers-city", "Lead-gen site for roofers in one city", "SEO/local search", "Build a local roofing lead-gen site and sell verified leads.", ["Local search volume", "CPC proxy", "Buyer outreach interest"], ["Landing pages", "Lead form", "Partner list"], ["Local ad/lead-sale compliance"]),
        lead("leadgen-plumbers-city", "Lead-gen site for plumbers in one city", "SEO/local search", "Build a city-specific plumber lead-gen site.", ["Search demand", "Competitor SERP weakness", "Provider buyer interest"], ["Landing pages", "Lead form", "Call tracking plan"], ["No fake local identity"]),
        lead("leadgen-med-spas-city", "Lead-gen site for med spas in one city", "SEO/local search", "Generate appointment leads for med spas in one city.", ["Treatment search volume", "Provider outreach interest", "Lead value estimate"], ["Service pages", "Lead capture", "Partner list"], ["Avoid medical claims"]),
        lead("leadgen-divorce-lawyers-city", "Lead-gen site for divorce lawyers in one city", "SEO/local search", "Generate consultation leads for divorce lawyers.", ["Legal keyword demand", "CPC proxy", "Lawyer buyer validation"], ["Landing pages", "Lead form", "Disclosure copy"], ["Legal advertising rules"]),
        lead("leadgen-accountants-city", "Lead-gen site for accountants in one city", "SEO/local search", "Generate leads for accountants/bookkeepers in a local niche.", ["Search demand", "Seasonality", "Buyer outreach"], ["Landing pages", "Lead form", "Partner list"], ["No tax advice"]),
        lead("leadgen-mortgage-brokers-city", "Lead-gen site for mortgage brokers in one city", "SEO/local search", "Generate mortgage consultation leads.", ["Keyword demand", "Lead value estimate", "Broker interest"], ["Landing pages", "Calculator", "Lead form"], ["Financial disclosures"]),
        lead("leadgen-home-cleaners-city", "Lead-gen site for home cleaners in one city", "SEO/local search", "Generate cleaning service leads.", ["Local search volume", "Provider buyer interest", "Conversion estimate"], ["Landing pages", "Quote form", "Partner list"], ["No fake reviews"]),
        lead("leadgen-wedding-photographers-city", "Lead-gen site for wedding photographers in one city", "SEO/local search", "Generate wedding photographer inquiry leads.", ["Wedding search demand", "Photographer buyer validation", "Seasonality"], ["Venue pages", "Lead form", "Partner list"], ["Transparent lead brokerage"]),
        lead("leadgen-private-tutors-city", "Lead-gen site for private tutors in one city", "SEO/local search", "Generate tutoring leads by subject and city.", ["Subject search demand", "Tutor buyer interest", "Parent pain evidence"], ["Subject pages", "Lead form", "Partner list"], ["Child safety/privacy"]),
        lead("leadgen-senior-care-city", "Lead-gen site for senior care providers in one city", "SEO/local search", "Generate senior care consultation leads.", ["Local search demand", "Provider buyer validation", "Lead value"], ["Landing pages", "Lead form", "Resource guide"], ["Sensitive-care disclaimers"]),

        realEstate("real-estate-rental-comp-reports", "Real estate rental comp report service", "Direct sales/SEO", "Sell rental comp reports to landlords and investors.", ["Investor demand", "Comparable data availability", "Willingness to pay"], ["Report template", "Sample report", "Checkout"], ["Data freshness", "No investment guarantees"]),
        realEstate("real-estate-expired-listing-assistant", "Real estate expired listing outreach assistant", "B2B service", "Offer agents a service that drafts and organizes expired-listing outreach.", ["Agent pain validation", "Data access feasibility", "Price test"], ["Service page", "Workflow", "Sample scripts"], ["Respect MLS/data rules"]),
        realEstate("real-estate-airbnb-revenue-estimates", "Real estate Airbnb revenue estimate reports", "Direct sales/SEO", "Sell short-term rental revenue estimate reports.", ["STR search demand", "Data source quality", "Investor willingness to pay"], ["Report template", "Landing page", "Checkout"], ["No income guarantees"]),
        realEstate("real-estate-deal-screener-newsletter", "Real estate investor deal screener newsletter", "Newsletter", "Curate and score potential deals for investors.", ["Investor signup demand", "Deal source reliability", "Paid tier interest"], ["Landing page", "Scoring model", "Issue template"], ["No investment advice"]),
        realEstate("real-estate-price-change-tracker", "Real estate neighborhood price-change tracker", "SEO/newsletter", "Track price changes by neighborhood and monetize with leads/sponsors.", ["Neighborhood search demand", "Data availability", "Sponsor fit"], ["Tracker pages", "Newsletter", "Lead form"], ["Source data clearly"]),
        realEstate("real-estate-listing-description-service", "Real estate agent listing description service", "Productized service", "Write listing descriptions, social captions, and flyer copy for agents.", ["Agent outreach replies", "Sample quality approval", "Price test"], ["Order page", "Samples", "Delivery workflow"], ["Avoid fair-housing violations"]),
        realEstate("real-estate-open-house-followup", "Real estate open-house follow-up automation", "B2B automation", "Automate follow-up texts/emails after open houses.", ["Agent pain validation", "CRM integration feasibility", "Price test"], ["Landing page", "Automation workflow", "Demo"], ["Messaging consent rules"]),
        realEstate("real-estate-fsbo-lead-research", "Real estate FSBO lead research service", "Productized service", "Research FSBO leads and prepare outreach packs for agents.", ["Agent buyer validation", "Source feasibility", "Lead quality"], ["Order page", "Sample pack", "Workflow"], ["Respect platform terms"]),
        realEstate("real-estate-tax-appeal-packet", "Real estate property tax appeal packet generator", "Digital/service hybrid", "Create property tax appeal packets using public data.", ["Search demand", "Data availability", "Willingness to pay"], ["Packet template", "Landing page", "Checkout"], ["No legal advice"]),
        realEstate("real-estate-relocation-guides", "Real estate relocation guide by city", "SEO/lead-gen", "Publish relocation guides monetized by realtor/mover leads.", ["Relocation search demand", "Local sponsor interest", "Lead value"], ["Guide pages", "Lead forms", "Partner list"], ["Keep local facts current"]),

        automation("automation-dentist-missed-calls", "AI automation service for dentists: missed-call follow-up", "B2B outreach", "Install missed-call follow-up workflows for dental practices.", ["Practice pain validation", "Demo call booked", "Price acceptance"], ["Landing page", "Demo workflow", "Outreach list"], ["HIPAA/privacy caution"]),
        automation("automation-med-spa-lead-intake", "AI automation service for med spas: lead intake", "B2B outreach", "Automate med spa lead intake and follow-up.", ["Med spa response rate", "Demo interest", "Price test"], ["Landing page", "Automation demo", "Outreach copy"], ["No medical claims"]),
        automation("automation-gym-trial-followup", "AI automation service for gyms: trial follow-up", "B2B outreach", "Automate trial signup follow-up for gyms.", ["Gym owner replies", "Workflow demo", "Close rate"], ["Landing page", "Demo workflow", "Outreach list"], ["Messaging consent"]),
        automation("automation-law-firm-intake", "AI automation service for law firms: intake summaries", "B2B outreach", "Create intake summary automations for small law firms.", ["Law firm pain validation", "Demo interest", "Compliance review"], ["Landing page", "Demo", "Security notes"], ["Attorney-client confidentiality"]),
        automation("automation-recruiter-screening", "AI automation service for recruiters: candidate screening", "B2B outreach", "Automate candidate summaries and screening notes for recruiters.", ["Recruiter replies", "ATS fit", "Price test"], ["Landing page", "Demo workflow", "Outreach"], ["Bias/fair hiring caution"]),
        automation("automation-agency-proposals", "AI automation service for agencies: proposal drafts", "B2B outreach", "Generate proposal drafts and scope docs for agencies.", ["Agency pain validation", "Sample approval", "Price test"], ["Landing page", "Proposal demo", "Workflow"], ["No confidential data leakage"]),
        automation("automation-realtor-listing-marketing", "AI automation service for realtors: listing marketing", "B2B outreach", "Create listing marketing packs for realtors.", ["Agent response rate", "Sample approval", "Price test"], ["Landing page", "Sample pack", "Workflow"], ["Fair-housing compliance"]),
        automation("automation-contractor-quote-followup", "AI automation service for contractors: quote follow-up", "B2B outreach", "Automate quote follow-up for home service contractors.", ["Contractor replies", "Demo interest", "Close rate"], ["Landing page", "Automation demo", "Outreach"], ["Messaging consent"]),
        automation("automation-coach-content-repurposing", "AI automation service for coaches: content repurposing", "B2B outreach", "Repurpose coach long-form content into posts, emails, and short scripts.", ["Coach buyer validation", "Sample approval", "Price test"], ["Landing page", "Sample pack", "Delivery workflow"], ["Rights to source content"]),
        automation("automation-restaurant-review-replies", "AI automation service for restaurants: review replies", "B2B outreach", "Draft restaurant review replies and escalation summaries.", ["Restaurant owner replies", "Demo quality", "Price test"], ["Landing page", "Demo", "Outreach list"], ["Do not post without approval"]),

        saas("saas-freelancer-invoice-reminders", "Micro-SaaS: invoice reminder tool for freelancers", "Own site", "Build a simple invoice reminder and follow-up tool for freelancers.", ["Freelancer pain validation", "Waitlist signups", "Payment intent"], ["Landing page", "MVP", "Stripe test"], ["Payment/security basics"]),
        saas("saas-agency-onboarding-portal", "Micro-SaaS: client onboarding portal for small agencies", "Own site", "Build a lightweight onboarding portal for small agencies.", ["Agency interviews", "Waitlist", "Paid beta interest"], ["Landing page", "MVP", "Demo"], ["Client data privacy"]),
        saas("saas-testimonial-collector", "Micro-SaaS: testimonial collector for service businesses", "Own site", "Collect, approve, and display testimonials for service businesses.", ["Buyer interviews", "Waitlist", "Competitor gap"], ["Landing page", "MVP", "Widget"], ["Consent and claims"]),
        saas("saas-review-response-assistant", "Micro-SaaS: Google review response assistant", "Own site", "Draft review responses and track review status.", ["Local business demand", "Waitlist", "Price test"], ["Landing page", "MVP", "Demo"], ["No auto-post without approval"]),
        saas("saas-shopify-seo-meta-generator", "Micro-SaaS: SEO title/meta generator for Shopify stores", "Own site/app marketplace", "Generate SEO titles and descriptions for Shopify products.", ["Shopify seller demand", "App marketplace research", "Signup intent"], ["Landing page", "MVP", "Demo"], ["Avoid keyword stuffing"]),
        saas("saas-creator-utm-tracker", "Micro-SaaS: UTM/link tracker for creators", "Own site", "Track campaign links and simple attribution for creators.", ["Creator interviews", "Waitlist", "Competitor gap"], ["Landing page", "MVP", "Dashboard"], ["Privacy-friendly tracking"]),
        saas("saas-etsy-refund-policy-generator", "Micro-SaaS: refund policy generator for Etsy sellers", "Own site", "Generate shop policy drafts and checklists for Etsy sellers.", ["Seller pain", "Signup intent", "SEO demand"], ["Landing page", "Generator MVP", "Disclaimer"], ["No legal advice"]),
        saas("saas-niche-content-calendar", "Micro-SaaS: content calendar generator by niche", "Own site", "Generate niche-specific content calendars and captions.", ["Creator/business demand", "Paid beta interest", "SEO demand"], ["Landing page", "MVP", "Example outputs"], ["No spam automation"]),
        saas("saas-local-price-tracker", "Micro-SaaS: competitor price tracker for local services", "Own site", "Track competitor prices/offers for local service businesses.", ["Business owner interviews", "Data feasibility", "Price test"], ["Landing page", "MVP", "Sample report"], ["Respect scraping terms"]),
        saas("saas-job-application-tracker", "Micro-SaaS: job application tracker with AI cover letters", "Own site", "Help job seekers track applications and draft tailored cover letters.", ["Job seeker demand", "Signup rate", "Price test"], ["Landing page", "MVP", "Templates"], ["No job guarantees"]),

        affiliate("affiliate-tools-for-profession", "Affiliate site: best tools for one profession", "SEO", "Build an affiliate site comparing tools for one profession.", ["Buyer-intent keywords", "Affiliate programs", "SERP weakness"], ["SEO pages", "Comparison tables", "Disclosure"], ["Affiliate disclosure"]),
        affiliate("affiliate-freelancer-software-stack", "Affiliate site: software stack for freelancers", "SEO/newsletter", "Recommend software stacks for freelancers by specialty.", ["Keyword demand", "Affiliate fit", "Newsletter signup"], ["Pages", "Lead magnet", "Disclosure"], ["Keep recommendations honest"]),
        affiliate("affiliate-home-office-reviews", "Affiliate site: home office product reviews", "SEO/YouTube", "Review home office products for a narrow worker segment.", ["Buyer keywords", "Affiliate availability", "Product data"], ["Review pages", "Comparison tables", "Disclosure"], ["Avoid fake hands-on claims"]),
        affiliate("affiliate-ai-tools-by-industry", "Affiliate site: AI tools by industry", "SEO/newsletter", "Compare AI tools for specific industries.", ["Industry keyword demand", "Affiliate programs", "Search weakness"], ["Comparison pages", "Newsletter", "Disclosure"], ["Test tools before claims"]),
        affiliate("affiliate-creator-gear-comparisons", "Affiliate site: creator gear comparisons", "SEO/YouTube", "Compare creator gear for one niche.", ["Buyer keywords", "Affiliate availability", "Video fit"], ["Review pages", "Videos/scripts", "Disclosure"], ["No fake ownership claims"]),
        service("course-canva-for-realtors", "Digital course: Canva for realtors", "Gumroad/own site", "Create a short course teaching realtors listing/social design workflows.", ["Realtor demand", "Preorder/waitlist", "Template upsell"], ["Course outline", "Lessons", "Sales page"], ["No income guarantees"]),
        service("course-ai-automations-local-business", "Digital course: AI automations for local businesses", "Gumroad/own site", "Teach local businesses practical AI automation workflows.", ["Owner pain validation", "Preorder interest", "Affiliate fit"], ["Course", "Templates", "Sales page"], ["Do not overpromise"]),
        service("course-etsy-digital-product-kit", "Digital course: Etsy digital product launch kit", "Gumroad/own site", "Teach a focused Etsy digital product workflow with templates.", ["Seller demand", "Preorder/waitlist", "Content validation"], ["Course", "Workbook", "Sales page"], ["No income guarantees"]),
        service("service-local-seo-pages", "Productized service: 30 SEO pages for local businesses", "B2B outreach", "Sell done-for-you local SEO page packs to service businesses.", ["Business owner replies", "Sample approval", "Price test"], ["Landing page", "Sample pages", "Delivery workflow"], ["Avoid duplicate/thin content"]),
        service("service-digital-product-shop-setup", "Productized service: done-for-you digital product shop setup", "B2B/creator outreach", "Set up Etsy/Gumroad digital product shops for creators and operators.", ["Creator replies", "Portfolio sample", "Price test"], ["Landing page", "Setup checklist", "Sample shop"], ["No guaranteed sales"])
    ]

    static func template(id: String) -> CompanyTemplate? {
        all.first { $0.id == id }
    }

    private static func digital(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .digitalProducts, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 30)
    }

    private static func kdp(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .kdp, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 60)
    }

    private static func media(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .creatorMedia, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 60)
    }

    private static func newsletter(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .newsletter, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 60)
    }

    private static func lead(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .leadGeneration, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 240)
    }

    private static func realEstate(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .realEstate, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 240)
    }

    private static func automation(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .automationService, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 60)
    }

    private static func saas(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .microSaaS, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 120)
    }

    private static func affiliate(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .affiliate, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 240)
    }

    private static func service(_ id: String, _ title: String, _ channel: String, _ mission: String, _ validation: [String], _ assets: [String], _ risks: [String]) -> CompanyTemplate {
        CompanyTemplate(id: id, title: title, category: .productizedService, channel: channel, mission: mission, validationSignals: validation, launchAssets: assets, riskNotes: risks, suggestedCadenceMinutes: 60)
    }
}
