import {fontFamily, loadFont} from '@remotion/google-fonts/Montserrat';

loadFont();

export const colors = {
	backgroundStart: '#fbfcff',
	backgroundEnd: '#f3f7fd',
	text: '#1f4a91',
	muted: '#697892',
	ink: '#1f4a91',
	inkSoft: '#4f78c5',
	inkMuted: '#697892',
	paper: '#f7f9fd',
	paperAlt: '#eef3fb',
	borderLight: 'rgba(32,75,151,0.10)',
	surfaceLight: 'rgba(255,255,255,0.82)',
	danger: '#ff3b3b',
	safe: '#00e676',
	accent: '#5c88ff',
	accentSoft: '#8bb0ff',
	accentGlow: 'rgba(92,136,255,0.18)',
	amber: '#ffb300',
	surface: 'rgba(255,255,255,0.86)',
	border: 'rgba(32,75,151,0.10)',
};

export const fonts = {
	headline: fontFamily,
	body: fontFamily,
};

export const frameConstants = {
	width: 1920,
	height: 1080,
	fps: 30,
	durationInFrames: 2700,
};
