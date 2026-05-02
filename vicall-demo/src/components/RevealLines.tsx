import React, {CSSProperties} from 'react';
import {interpolate, spring} from 'remotion';

type RevealLine = {
	text: string;
	style?: CSSProperties;
};

export const RevealLines: React.FC<{
	lines: RevealLine[];
	frame: number;
	fps: number;
	startFrame?: number;
	staggerFrames?: number;
	durationInFrames?: number;
	gap?: number;
	translateY?: number;
	blur?: number;
	containerStyle?: CSSProperties;
	lineStyle?: CSSProperties;
}> = ({
	lines,
	frame,
	fps,
	startFrame = 0,
	staggerFrames = 5,
	durationInFrames = 24,
	gap = 0,
	translateY = 24,
	blur = 14,
	containerStyle,
	lineStyle,
}) => {
	return (
		<div
			style={{
				display: 'flex',
				flexDirection: 'column',
				gap,
				...containerStyle,
			}}
		>
			{lines.map((line, index) => {
				const localFrame = Math.max(0, frame - startFrame - index * staggerFrames);
				const enter = spring({
					fps,
					frame: localFrame,
					config: {damping: 18, stiffness: 118},
					durationInFrames,
				});

				return (
					<div
						key={`${line.text}-${index}`}
						style={{
							opacity: enter,
							transform: `translateY(${interpolate(enter, [0, 1], [translateY, 0])}px)`,
							filter: `blur(${interpolate(enter, [0, 1], [blur, 0])}px)`,
							letterSpacing: `${interpolate(enter, [0, 1], [0.8, 0])}px`,
							...lineStyle,
							...line.style,
						}}
					>
						{line.text}
					</div>
				);
			})}
		</div>
	);
};
