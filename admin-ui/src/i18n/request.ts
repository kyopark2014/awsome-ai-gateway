// Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

import { getRequestConfig } from 'next-intl/server';
import { cookies } from 'next/headers';

const SUPPORTED_LOCALES = ['ko', 'en'] as const;
type Locale = (typeof SUPPORTED_LOCALES)[number];

export default getRequestConfig(async () => {
  const cookieStore = cookies();
  const raw = cookieStore.get('locale')?.value;
  const locale: Locale =
    raw && SUPPORTED_LOCALES.includes(raw as Locale) ? (raw as Locale) : 'ko';

  return {
    locale,
    messages: (await import(`../../messages/${locale}.json`)).default,
  };
});
