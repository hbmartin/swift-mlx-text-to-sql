import AutoTableCharts

func chartTestRecommendationID(
  _ rawValue: String = "test-specification",
  policyVersion: Int = AutoTableCharts.recommendationPolicyVersion
) -> AutoChartRecommendationID {
  AutoChartRecommendationID(
    policyVersion: policyVersion,
    specificationID: AutoChartSpecificationID(rawValue: rawValue))
}
