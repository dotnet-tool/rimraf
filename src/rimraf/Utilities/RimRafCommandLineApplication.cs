using McMaster.Extensions.CommandLineUtils;

namespace RimRaf.Utilities
{
    internal class RimRafCommandLineApplication : CommandLineApplication
    {
        public override string GetFullNameAndVersion()
        {
            string shortVersion = ShortVersionGetter?.Invoke();

            if (string.IsNullOrEmpty(FullName)  && string.IsNullOrEmpty(shortVersion)) return string.Empty;
            if (!string.IsNullOrEmpty(FullName) && string.IsNullOrEmpty(shortVersion)) return FullName;
            if (string.IsNullOrEmpty(FullName)  && !string.IsNullOrEmpty(shortVersion)) return shortVersion;

            return $"{FullName} ({shortVersion})";
        }

        public override string GetVersionText()
        {
            return LongVersionGetter();
        }
    }
}