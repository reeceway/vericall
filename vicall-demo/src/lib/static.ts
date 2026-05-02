import {getStaticFiles, staticFile} from 'remotion';

export const hasStaticAsset = (path: string): boolean => {
	return getStaticFiles().some((file) => {
		const src = typeof file.src === 'string' ? file.src : '';
		return file.name === path || src.endsWith(`/${path}`) || src === path;
	});
};

export const staticAsset = (path: string): string | null => {
	return hasStaticAsset(path) ? staticFile(path) : null;
};
