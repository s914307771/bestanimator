import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {title:'BEST Animator CRM',description:'Управление заказами и мероприятиями BEST Animator'};
export default function RootLayout({children}:{children:React.ReactNode}) {return <html lang="ru"><body>{children}</body></html>}
