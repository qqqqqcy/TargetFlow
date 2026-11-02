import Foundation

extension GeminiDirectProvider {
  func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
    TimelineOutputPolicy().categoriesSection(from: descriptors)
  }

  func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
    TimelineOutputPolicy().normalizeCategory(raw, descriptors: descriptors)
  }

  func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor])
    -> [ActivityCardData]
  {
    TimelineOutputPolicy().normalizeCards(cards, descriptors: descriptors)
  }
}
