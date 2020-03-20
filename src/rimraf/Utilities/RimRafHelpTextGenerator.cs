using System.IO;

using McMaster.Extensions.CommandLineUtils;
using McMaster.Extensions.CommandLineUtils.HelpText;

namespace RimRaf.Utilities
{
    internal class RimRafHelpTextGenerator : DefaultHelpTextGenerator
    {
        protected override void GenerateFooter(CommandLineApplication application, TextWriter output)
        {
            output.Write(application.ExtendedHelpText);
        }
    }
}