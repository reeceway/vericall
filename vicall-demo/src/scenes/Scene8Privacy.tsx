import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

const lines = [
	'On-device detection',
	'No cloud inference for alerts',
	'No recordings stored by Vicall',
];

export const Scene8Privacy: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();

	return (
		<SceneContainer durationInFrames={durationInFrames}>
			<div
				style={{
					flex: 1,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					justifyContent: 'center',
					gap: 30,
				}}
			>
				{lines.map((line, index) => {
					const local = Math.max(0, frame - index * 25);
					const progress = spring({
						fps,
						frame: local,
						config: {damping: 180, stiffness: 220},
						durationInFrames: 22,
					});
					return (
						<div
							key={line}
							style={{
								fontFamily: fonts.body,
								fontSize: 50,
								color: colors.text,
								opacity: progress,
								transform: `translateY(${interpolate(progress, [0, 1], [20, 0])}px)`,
								filter: `blur(${interpolate(progress, [0, 1], [8, 0])}px)`,
							}}
						>
							<span style={{color: colors.safe, marginRight: 16}}>✓</span>
							{line}
						</div>
					);
				})}
			</div>
		</SceneContainer>
	);
};
