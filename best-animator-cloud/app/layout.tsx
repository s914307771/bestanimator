import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {
  title: 'Double Bubble Show | CRM v0.9',
  description: 'Система управления заказами, персонажами и праздниками Double Bubble Show',
  icons: { icon: '/dbs-icon.png', apple: '/dbs-icon.png' },
};
export default function RootLayout({children}:{children:React.ReactNode}) {
  return <html lang="ru"><body>{children}</body></html>;
}
