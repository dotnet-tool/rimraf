using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;

using DotNet.Globbing;

using RimRaf.Extensions;

namespace RimRaf.Utilities
{
    internal class Matcher
    {
        private readonly ICollection<string> _excludePatterns;

        private readonly GlobOptions _globOptions;

        private readonly ICollection<string> _includePatterns;

        public Matcher()
            : this(StringComparison.OrdinalIgnoreCase) { }

        public Matcher(StringComparison stringComparison)
        {
            _excludePatterns = new Collection<string>();
            _includePatterns = new Collection<string>();

            _globOptions = new GlobOptions();
            switch (stringComparison)
            {
                case StringComparison.CurrentCultureIgnoreCase:
                case StringComparison.InvariantCultureIgnoreCase:
                case StringComparison.OrdinalIgnoreCase:
                    _globOptions.Evaluation.CaseInsensitive = true;
                    break;
                default:
                case StringComparison.CurrentCulture:
                case StringComparison.InvariantCulture:
                case StringComparison.Ordinal:
                    _globOptions.Evaluation.CaseInsensitive = false;
                    break;
            }
        }

        public string RootPath { get; set; }

        public virtual Matcher AddExclude(string pattern)
        {
            _excludePatterns.Add(PathExtensions.RemoveRelativeSegments(pattern));
            return this;
        }

        public virtual Matcher AddExcludes(params string[] patterns)
        {
            foreach (string pattern in patterns)
            {
                _excludePatterns.Add(PathExtensions.RemoveRelativeSegments(pattern));
            }

            return this;
        }

        public virtual Matcher AddInclude(string pattern)
        {
            _includePatterns.Add(PathExtensions.RemoveRelativeSegments(pattern));
            return this;
        }

        public virtual Matcher AddIncludes(params string[] patterns)
        {
            foreach (string pattern in patterns)
            {
                _includePatterns.Add(PathExtensions.RemoveRelativeSegments(pattern));
            }

            return this;
        }

        public virtual ICollection<string> Execute(string path)
        {
            RootPath = Path.GetFullPath(path);

            if (!Directory.Exists(RootPath)) throw new DirectoryNotFoundException($"Directory not exists: '{RootPath}'");

            IEnumerable<string> entries = Directory.EnumerateFileSystemEntries(RootPath, "*", SearchOption.AllDirectories);

            ICollection<string> includePatterns = PreparePatterns(RootPath, _includePatterns);
            ICollection<string> excludePatterns = PreparePatterns(RootPath, _excludePatterns);

            var includedEntries = new Collection<string>();
            foreach (string entry in entries)
            {
                if (includePatterns.Any(x => Glob.Parse(x, _globOptions).IsMatch(entry)))
                {
                    includedEntries.Add(entry);
                }
            }

            var excludedEntries = new Collection<string>();
            foreach (string entry in entries)
            {
                if (excludePatterns.Any(x => Glob.Parse(x, _globOptions).IsMatch(entry)))
                {
                    excludedEntries.Add(entry);
                }
            }

            var results = new Collection<string>();
            foreach (string entry in includedEntries)
            {
                if (!excludedEntries.Any(x => x.Contains(entry)))
                {
                    results.Add(entry);
                }
            }

            return results;
        }

        private static ICollection<string> PreparePatterns(string path, IEnumerable<string> patterns)
        {
            var preparedPatterns = new Collection<string>();

            foreach (string pattern in patterns)
            {
                preparedPatterns.Add(Path.Combine(path, pattern));
            }

            return preparedPatterns;
        }
    }
}