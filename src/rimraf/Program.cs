﻿using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

using Humanizer;

using McMaster.Extensions.CommandLineUtils;

using Polly;

using RimRaf.Extensions;
using RimRaf.Utilities;

using ShellProgressBar;

namespace RimRaf
{
    internal class Program
    {
        private const int Error = 1;

        private const int Ok = 0;

        private static CommandOption _excludesOption;

        private static CommandOption _includesOption;

        private static CommandOption _listItemsOption;

        private static CommandArgument _pathArgument;

        private static CommandOption _quietOption;

        private static CommandOption _skipPathOption;

        private static CommandOption _tryRunOption;

        private static CommandOption _verboseOption;

        public static Task<int> Main(string[] args)
        {
            var app = new RimRafCommandLineApplication
            {
                Name = "rimraf",
                FullName = "Safe deep deletion, like 'rm -rf'",
                Description = "rimraf is a safe deep deletion utility for .NET, much like 'rm -rf', just safer."
            };

            _pathArgument = app.Argument("Path", "The root path.").IsRequired();
            _includesOption = app.Option("-i|--include <PATTERN>",
                                         "Include pattern.\r\nSee: https://github.com/dazinator/DotNet.Glob",
                                         CommandOptionType.MultipleValue);
            _excludesOption = app.Option("-e|--exclude <PATTERN>",
                                         "Exclude pattern.\r\nSee: https://github.com/dazinator/DotNet.Glob",
                                         CommandOptionType.MultipleValue);
            _skipPathOption = app.Option("-s|--skip-path", "Skip deletion of the root path when is empty.", CommandOptionType.NoValue);
            _listItemsOption = app.Option("-l|--list", "Only list the relevant files and directories.", CommandOptionType.NoValue);
            _tryRunOption = app.Option("-t|--try-run", "Only try a run (No files and directories will be deleted).", CommandOptionType.NoValue);
            _quietOption = app.Option("-q|--quiet", "Quiet output.", CommandOptionType.NoValue);
            _verboseOption = app.Option("--verbose", "Verbose output.", CommandOptionType.NoValue);

            app.VersionOption("-v|--version", ThisAssembly.AssemblyInformationalVersion, ThisAssembly.AssemblyInformationalVersion);
            app.HelpOption("-?|-h|--help");

            app.OnExecuteAsync(ExecuteAsync);

            try
            {
                return Task.FromResult(app.Execute(args));
            }
            catch (Exception ex)
            {
                ConsoleColor bakForegroundColor = Console.ForegroundColor;
                Console.ForegroundColor = ConsoleColor.Red;

                Console.WriteLine($"ERROR: {ex.Message}");

                Console.ForegroundColor = bakForegroundColor;

                return Task.FromResult(Error);
            }
        }

        private static Task<int> ExecuteAsync(CancellationToken cancellationToken)
        {
            var includePattern = _includesOption.Values;
            var excludePattern = _excludesOption.Values;

            // When no include pattern is specified, we decide to include all recursive ('**')
            if (!includePattern.Any())
            {
                includePattern.Add("**");
            }

            var matcher = new Matcher(StringComparison.OrdinalIgnoreCase);
            matcher.AddIncludePatterns(includePattern);
            matcher.AddExcludePatterns(excludePattern);

            var stopwatch = Stopwatch.StartNew();

            var items = matcher.Execute(_pathArgument.Value);
            int totalItems = items.Count;
            TimeSpan getItemsElapsed = stopwatch.Elapsed;

            void ExecuteWithProgressBar(Action<string> itemAction, Action<DirectoryInfo, Func<bool>> rootPathAction)
            {
                var options = new ProgressBarOptions { ProgressCharacter = '─', CollapseWhenFinished = false };
                using var progressBar = new ProgressBar(totalItems, "Start remove items...", options);
                var i = 0;

                foreach (string path in items.OrderByDescending(x => x.Length))
                {
                    string shrinkedPath = PathFormatter.ShrinkPath(path, Console.BufferWidth - 44);

                    progressBar.Message = $"Remove item {i + 1} of {totalItems}: {shrinkedPath}";

                    itemAction(path);

                    progressBar.Tick($"Removed item {i + 1} of {totalItems}: {shrinkedPath}");

                    ++i;
                }

                var rootPathDirectoryInfo = new DirectoryInfo(matcher.RootPath);
                var rootPathCheck = new Func<bool>(() => rootPathDirectoryInfo.Exists
                                                      && rootPathDirectoryInfo.GetFileSystemInfos("*", SearchOption.AllDirectories).Length == 0);

                if ((_skipPathOption.HasValue() || !rootPathCheck()) && (_skipPathOption.HasValue() || !_tryRunOption.HasValue())) return;

                using ChildProgressBar childProgressBar = progressBar.Spawn(1, "child actions", options);
                {
                    string shrinkedPath = PathFormatter.ShrinkPath(matcher.RootPath, Console.BufferWidth - 44);

                    childProgressBar.Message = $"Remove empty root path: {shrinkedPath}";

                    rootPathAction(rootPathDirectoryInfo, rootPathCheck);

                    childProgressBar.Tick($"Removed empty root path: {shrinkedPath}");
                }
            }

            void ExecuteQuiet(Action<string> itemAction, Action<DirectoryInfo, Func<bool>> rootPathAction)
            {
                foreach (string path in items.OrderByDescending(x => x.Length))
                {
                    itemAction(path);
                }

                var rootPathDirectoryInfo = new DirectoryInfo(matcher.RootPath);
                var rootPathCheck = new Func<bool>(() => rootPathDirectoryInfo.Exists
                                                      && rootPathDirectoryInfo.GetFileSystemInfos("*", SearchOption.AllDirectories).Length == 0);

                if (!_skipPathOption.HasValue() && rootPathCheck() || !_skipPathOption.HasValue() && _tryRunOption.HasValue())
                {
                    rootPathAction(rootPathDirectoryInfo, rootPathCheck);
                }
            }

            if (totalItems > 0)
            {
                var retryPolicy = Policy.Handle<Exception>().OrResult<bool>(r => r).WaitAndRetry(25, c => TimeSpan.FromMilliseconds(250));

                var itemAction = new Action<string>(path =>
                                                    {
                                                        if (_tryRunOption.HasValue())
                                                        {
                                                            Thread.Sleep(1);
                                                        }
                                                        else
                                                        {
                                                            if (PathExtensions.IsDirectory(path))
                                                            {
                                                                var di = new DirectoryInfo(path);
                                                                retryPolicy.Execute(() =>
                                                                                    {
                                                                                        di.Refresh();
                                                                                        if (di.Exists)
                                                                                        {
                                                                                            di.Attributes = FileAttributes.Normal;
                                                                                            di.Delete(true);
                                                                                        }

                                                                                        di.Refresh();
                                                                                        return di.Exists;
                                                                                    });
                                                            }
                                                            else
                                                            {
                                                                var fi = new FileInfo(path);
                                                                retryPolicy.Execute(() =>
                                                                                    {
                                                                                        fi.Refresh();
                                                                                        if (fi.Exists)
                                                                                        {
                                                                                            fi.Attributes = FileAttributes.Normal;
                                                                                            fi.Delete();
                                                                                        }

                                                                                        fi.Refresh();
                                                                                        return fi.Exists;
                                                                                    });
                                                            }
                                                        }
                                                    });
                var rootPathAction = new Action<DirectoryInfo, Func<bool>>((di, check) =>
                                                                           {
                                                                               if (_tryRunOption.HasValue())
                                                                               {
                                                                                   Thread.Sleep(1);
                                                                               }
                                                                               else
                                                                               {
                                                                                   retryPolicy.Execute(() =>
                                                                                                       {
                                                                                                           di.Refresh();
                                                                                                           if (check())
                                                                                                           {
                                                                                                               di.Attributes = FileAttributes.Normal;
                                                                                                               di.Delete();
                                                                                                           }

                                                                                                           di.Refresh();
                                                                                                           return check();
                                                                                                       });
                                                                               }
                                                                           });

                if (!_listItemsOption.HasValue() && !_quietOption.HasValue())
                {
                    ExecuteWithProgressBar(itemAction, rootPathAction);
                }
                else if (_listItemsOption.HasValue() && !_quietOption.HasValue())
                {
                    foreach (string path in items.OrderByDescending(x => x.Length))
                    {
                        Console.WriteLine(path);
                    }

                    if (!_skipPathOption.HasValue())
                    {
                        Console.WriteLine(matcher.RootPath);
                    }
                }
                else if (!_listItemsOption.HasValue() && _quietOption.HasValue())
                {
                    ExecuteQuiet(itemAction, rootPathAction);
                }
            }

            stopwatch.Stop();
            TimeSpan completeElapsed = stopwatch.Elapsed;

            if (_listItemsOption.HasValue() || _quietOption.HasValue()) return Task.FromResult(Ok);

            PrintSummary(totalItems, completeElapsed, getItemsElapsed);

            return Task.FromResult(Ok);
        }

        private static void PrintSummary(int totalItems, TimeSpan completeElapsed, TimeSpan getItemsElapsed)
        {
            var totalItemsMessage = string.Empty;
            if (totalItems <= 0)
            {
                totalItemsMessage = "Total:               No items found!";
            }
            else if (totalItems == 1)
            {
                totalItemsMessage = $"Total:              {totalItems} item";
            }
            else if (totalItems > 1)
            {
                totalItemsMessage = $"Total:              {totalItems} items";
            }

            string timeElapsedMessage = $"Total Time elapsed: {completeElapsed.Humanize(2)} ({completeElapsed})";
            int columnLength = Math.Max(totalItemsMessage.Length, timeElapsedMessage.Length);

            ConsoleColor bakForegroundColor = Console.ForegroundColor;

            Console.ForegroundColor = ConsoleColor.DarkGreen;
            Console.WriteLine(new string('=', columnLength));
            Console.WriteLine("Summary");
            Console.WriteLine(new string('-', columnLength));
            Console.WriteLine(totalItemsMessage);
            Console.WriteLine(new string('=', columnLength));

            Console.ForegroundColor = ConsoleColor.DarkYellow;
            Console.WriteLine(timeElapsedMessage);

            Console.WriteLine($"Get items:          {getItemsElapsed.Humanize(2)} ({getItemsElapsed})");
            Console.WriteLine($"Process items:      {(completeElapsed - getItemsElapsed).Humanize(2)} ({completeElapsed - getItemsElapsed})");

            Console.ForegroundColor = bakForegroundColor;
        }
    }
}