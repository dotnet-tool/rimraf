using System;
using System.IO;
using System.Linq;
using System.Text;

namespace RimRaf.Extensions
{
    internal static class PathExtensions
    {
        public static void EnsureDirectoryExists(string path)
        {
            string directoryPath = Path.GetDirectoryName(path);
            if (!Directory.Exists(directoryPath))
            {
                Directory.CreateDirectory(directoryPath);
            }
        }

        public static string GetFullPathWithEndingSlashes(string path)
        {
            string fullPath = Path.GetFullPath(path);
            return fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        }

        public static string GetLastSegment(string path)
        {
            path = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string lastSegment = path.Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries)
                                     .Last();
            return lastSegment;
        }

        public static bool IsDirectory(string path)
        {
            FileAttributes fileAttributes = File.GetAttributes(path);
            return (fileAttributes & FileAttributes.Directory) != 0;
        }

        /// <summary>
        /// Normalize separators in the given path. Converts forward slashes into back slashes and compresses slash runs, keeping initial 2 if present.
        /// Also trims initial whitespace in front of "rooted" paths (see PathStartSkip).
        ///
        /// This effectively replicates the behavior of the legacy NormalizePath when it was called with fullCheck=false and expandShortpaths=false.
        /// The current NormalizePath gets directory separator normalization from Win32's GetFullPathName(), which will resolve relative paths and as
        /// such can't be used here (and is overkill for our uses).
        ///
        /// Like the current NormalizePath this will not try and analyze periods/spaces within directory segments.
        /// </summary>
        /// <remarks>
        /// The only callers that used to use Path.Normalize(fullCheck=false) were Path.GetDirectoryName() and Path.GetPathRoot(). Both usages do
        /// not need trimming of trailing whitespace here.
        ///
        /// GetPathRoot() could technically skip normalizing separators after the second segment- consider as a future optimization.
        ///
        /// For legacy desktop behavior with ExpandShortPaths:
        /// - It has no impact on GetPathRoot() so doesn't need consideration.
        /// - It could impact GetDirectoryName(), but only if the path isn't relative (C:\ or \\Server\Share).
        ///
        /// In the case of GetDirectoryName() the ExpandShortPaths behavior was undocumented and provided inconsistent results if the path was
        /// fixed/relative. For example: "C:\PROGRA~1\A.TXT" would return "C:\Program Files" while ".\PROGRA~1\A.TXT" would return ".\PROGRA~1". If you
        /// ultimately call GetFullPath() this doesn't matter, but if you don't or have any intermediate string handling could easily be tripped up by
        /// this undocumented behavior.
        ///
        /// We won't match this old behavior because:
        ///
        /// 1. It was undocumented
        /// 2. It was costly (extremely so if it actually contained '~')
        /// 3. Doesn't play nice with string logic
        /// 4. Isn't a cross-plat friendly concept/behavior
        /// </remarks>
        public static string NormalizeDirectorySeparators(string path)
        {
            if (string.IsNullOrEmpty(path))
                return path;

            char current;

            // Make a pass to see if we need to normalize so we can potentially skip allocating
            var normalized = true;

            for (var i = 0; i < path.Length; i++)
            {
                current = path[i];
                if (PathInternal.IsDirectorySeparator(current)
                    && (current != Path.DirectorySeparatorChar
                        // Check for sequential separators past the first position (we need to keep initial two for UNC/extended)
                        || i > 0 && i + 1 < path.Length && PathInternal.IsDirectorySeparator(path[i + 1])))
                {
                    normalized = false;
                    break;
                }
            }

            if (normalized)
                return path;

            var builder = new StringBuilder(path.Length);

            var start = 0;
            if (PathInternal.IsDirectorySeparator(path[start]))
            {
                start++;
                builder.Append(Path.DirectorySeparatorChar);
            }

            for (int i = start; i < path.Length; i++)
            {
                current = path[i];

                // If we have a separator
                if (PathInternal.IsDirectorySeparator(current))
                {
                    // If the next is a separator, skip adding this
                    if (i + 1 < path.Length && PathInternal.IsDirectorySeparator(path[i + 1]))
                    {
                        continue;
                    }

                    // Ensure it is the primary separator
                    current = Path.DirectorySeparatorChar;
                }

                builder.Append(current);
            }

            return builder.ToString();
        }

        /// <summary>
        /// Try to remove relative segments from the given path (without combining with a root).
        /// </summary>
        /// <param name="skip">Skip the specified number of characters before evaluating.</param>
        public static string RemoveRelativeSegments(string path, int skip = 0)
        {
            var flippedSeparator = false;

            // Remove "//", "/./", and "/../" from the path by copying each character to the output,
            // except the ones we're removing, such that the builder contains the normalized path
            // at the end.
            var sb = new StringBuilder(path.Length);
            if (skip > 0)
            {
                sb.Append(path, 0, skip);
            }

            for (int i = skip; i < path.Length; i++)
            {
                char c = path[i];

                if (PathInternal.IsDirectorySeparator(c) && i + 1 < path.Length)
                {
                    // Skip this character if it's a directory separator and if the next character is, too,
                    // e.g. "parent//child" => "parent/child"
                    if (PathInternal.IsDirectorySeparator(path[i + 1]))
                    {
                        continue;
                    }

                    // Skip this character and the next if it's referring to the current directory,
                    // e.g. "parent/./child" => "parent/child"
                    if ((i + 2 == path.Length || PathInternal.IsDirectorySeparator(path[i + 2])) && path[i + 1] == '.')
                    {
                        i++;
                        continue;
                    }

                    // Skip this character and the next two if it's referring to the parent directory,
                    // e.g. "parent/child/../grandchild" => "parent/grandchild"
                    if (i + 2 < path.Length
                        && (i + 3 == path.Length || PathInternal.IsDirectorySeparator(path[i + 3]))
                        && path[i + 1] == '.'
                        && path[i + 2] == '.')
                    {
                        // Unwind back to the last slash (and if there isn't one, clear out everything).
                        int s;
                        for (s = sb.Length - 1; s >= 0; s--)
                        {
                            if (PathInternal.IsDirectorySeparator(sb[s]))
                            {
                                sb.Length = s;
                                break;
                            }
                        }

                        if (s < 0)
                        {
                            sb.Length = 0;
                        }

                        i += 2;
                        continue;
                    }
                }

                // Normalize the directory separator if needed
                if (c != Path.DirectorySeparatorChar && c == Path.AltDirectorySeparatorChar)
                {
                    c = Path.DirectorySeparatorChar;
                    flippedSeparator = true;
                }

                sb.Append(c);
            }

            if (flippedSeparator || sb.Length != path.Length)
            {
                return sb.ToString();
            }
            else
            {
                // We haven't changed the source path, return the original
                return path;
            }
        }

        private static class PathInternal
        {
            public static bool IsDirectorySeparator(char c)
            {
                return c == Path.DirectorySeparatorChar;
            }
        }
    }
}