using System.Collections.Generic;

using RimRaf.Utilities;

namespace RimRaf.Extensions
{
    internal static class MatcherExtensions
    {
        public static void AddExcludePatterns(this Matcher matcher, params IEnumerable<string>[] excludePatternsGroups)
        {
            foreach (IEnumerable<string> excludePatternsGroup in excludePatternsGroups)
            {
                foreach (string pattern in excludePatternsGroup)
                    matcher.AddExclude(pattern);
            }
        }

        public static void AddIncludePatterns(this Matcher matcher, params IEnumerable<string>[] includePatternsGroups)
        {
            foreach (IEnumerable<string> includePatternsGroup in includePatternsGroups)
            {
                foreach (string pattern in includePatternsGroup)
                    matcher.AddInclude(pattern);
            }
        }
    }
}